import Foundation
import Testing
@testable import DeepSeekCore

@Suite("Web Adapter (手机端反代链路)")
struct WebAdapterTests {

    // MARK: 模板

    @Test("模板占位符替换")
    func templateRender() {
        let out = WebAdapterTemplate.render(
            #"{"prompt":"{{prompt}}","model":"{{model}}"}"#,
            values: ["prompt": "你好", "model": "deepseek-chat"]
        )
        #expect(out == #"{"prompt":"你好","model":"deepseek-chat"}"#)
    }

    @Test("转义后请求体仍是合法 JSON")
    func jsonEscapeKeepsBodyValid() throws {
        let tricky = "换行\n引号\"反斜杠\\结尾"
        let body = "{\"prompt\":\"\(WebAdapterTemplate.jsonEscape(tricky))\"}"
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(object?["prompt"] as? String == tricky)
    }

    // MARK: 点路径

    @Test("点路径支持数组下标")
    func jsonPath() {
        let object: [String: Any] = ["a": ["b": [["c": "命中"]]]]
        #expect(WebJSONPath.string(in: object, path: "a.b.0.c") == "命中")
        #expect(WebJSONPath.string(in: object, path: "a.b.9.c") == nil)
    }

    // MARK: 回包翻译

    @Test("DeepSeek 网页版 APPEND 补丁翻译成增量文本")
    func deepSeekPatch() {
        var extractor = WebDeltaExtractor(mode: .sseDeepSeek)
        let first = extractor.extract(#"{"p":"response/fragments/-1/content","o":"APPEND","v":"你"}"#)
        let second = extractor.extract(#"{"p":"response/fragments/-1/content","o":"APPEND","v":"好"}"#)
        #expect(first == [.content("你")])
        #expect(second == [.content("好")])
    }

    @Test("DeepSeek 思考补丁归到 reasoning")
    func deepSeekThinking() {
        var extractor = WebDeltaExtractor(mode: .sseDeepSeek)
        let delta = extractor.extract(#"{"p":"response/thinking_content","o":"APPEND","v":"先想一下"}"#)
        #expect(delta == [.reasoning("先想一下")])
    }

    @Test("豆包的整段快照被差分成增量")
    func doubaoSnapshotDiff() {
        var extractor = WebDeltaExtractor(mode: .sseDoubao)
        func payload(_ text: String) -> String {
            let inner = #"{"message":{"content":"\#(text)"}}"#
            let escaped = WebAdapterTemplate.jsonEscape(inner)
            return #"{"event_type":2001,"event_data":"\#(escaped)"}"#
        }
        #expect(extractor.extract(payload("答")) == [.content("答")])
        #expect(extractor.extract(payload("答案")) == [.content("案")])
        #expect(extractor.extract(payload("答案")) == [])
    }

    @Test("OpenAI 兼容流里 thinking 阶段单独拆出来")
    func openAIThinkingPhase() {
        var extractor = WebDeltaExtractor(mode: .sseOpenAI)
        let thinking = extractor.extract(#"{"choices":[{"delta":{"phase":"think","content":"推理中"}}]}"#)
        let answer = extractor.extract(#"{"choices":[{"delta":{"content":"结论"}}]}"#)
        #expect(thinking == [.reasoning("推理中")])
        #expect(answer == [.content("结论")])
    }

    // MARK: 凭据

    @Test("localStorage 里的 JSON 凭据按路径取值")
    func credentialJSONPath() {
        let local: [String: String] = [
            "userToken": #"{"value":"abc.def.ghi","__version":"0"}"#
        ]
        let token = WebCredentialParser.extract(
            spec: .deepSeekWeb, localStorage: local, cookies: [:]
        )
        #expect(token == "abc.def.ghi")
    }

    @Test("cookie 凭据会去掉 Bearer 前缀")
    func credentialBearerPrefix() {
        let token = WebCredentialParser.extract(
            spec: .qwenWeb, localStorage: [:], cookies: ["token": "Bearer eyJhbGciOi"]
        )
        #expect(token == "eyJhbGciOi")
    }

    @Test("没登录时凭据为空")
    func credentialMissing() {
        #expect(WebCredentialParser.extract(spec: .doubaoWeb, localStorage: [:], cookies: [:]) == nil)
    }

    // MARK: 错误信封

    @Test("HTTP 200 里的错误信封要被识别成人话")
    func errorEnvelopeDetected() {
        let object: [String: Any] = ["code": 40003, "msg": "INVALID_TOKEN", "data": NSNull()]
        let message = WebAdapterClient.errorEnvelope(from: object)
        #expect(message?.contains("40003") == true)
        #expect(message?.contains("重新登录") == true)
    }

    @Test("正常 chunk 不会被误判成错误")
    func normalChunkNotMistakenForError() {
        let object: [String: Any] = ["choices": [["delta": ["content": "你好"]]]]
        #expect(WebAdapterClient.errorEnvelope(from: object) == nil)
        let doubao: [String: Any] = ["event_type": 2001, "event_data": "{}"]
        #expect(WebAdapterClient.errorEnvelope(from: doubao) == nil)
    }

    @Test("PoW / 签名类报错给出明确提示")
    func powHint() {
        let object: [String: Any] = ["code": 40301, "msg": "MISSING_POW_SIGNATURE"]
        let message = WebAdapterClient.errorEnvelope(from: object) ?? ""
        #expect(message.contains("风控签名"))
    }

    // MARK: spec 编解码

    @Test("三个内置预设 JSON 往返一致")
    func presetsRoundTrip() throws {
        for spec in WebAdapterSpec.presets {
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(WebAdapterSpec.self, from: data)
            #expect(decoded == spec)
        }
    }

    @Test("请求体是合法 JSON 且带上了凭据与提示词")
    func requestBody() throws {
        let client = WebAdapterClient()
        let messages = [ChatMessage(role: .user, content: "写个快排")]
        let request = try client.makeRequest(
            spec: .deepSeekWeb, credential: "token-123", model: "deepseek-chat", messages: messages
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let prompt = try #require(object?["prompt"] as? String)
        #expect(prompt.contains("写个快排"))
        #expect(object?["stream"] as? Bool == true)
    }

    @Test("建会话后的 chat_session_id 会填进请求体")
    func sessionIDRendered() throws {
        let client = WebAdapterClient()
        let request = try client.makeRequest(
            spec: .deepSeekWeb, credential: "t", model: "deepseek-chat",
            messages: [ChatMessage(role: .user, content: "hi")],
            sessionID: "sess-123"
        )
        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(object?["chat_session_id"] as? String == "sess-123")
    }

    @Test("DeepSeek 预设带建会话配置，且 id 路径可解析")
    func deepSeekSessionBootstrapConfigured() {
        let spec = WebAdapterSpec.deepSeekWeb
        #expect(spec.sessionURL?.contains("chat_session/create") == true)
        let payload: [String: Any] = [
            "data": ["biz_data": ["chat_session": ["id": "abc"]]]
        ]
        let path = spec.sessionIdPath ?? ""
        #expect(WebJSONPath.string(in: payload, path: path) == "abc")
    }

    @Test("没有凭据时直接报错，不会发出请求")
    func requestRejectsEmptyCredential() {
        let client = WebAdapterClient()
        #expect(throws: WebAdapterError.missingCredential) {
            _ = try client.makeRequest(
                spec: .deepSeekWeb, credential: "   ", model: "deepseek-chat", messages: []
            )
        }
    }

    @Test("DeepSeekHashV1 摘要与官方 WASM 逐位一致且毫秒级解出真机挑战")
    func deepSeekPoWBitExact() {
        #expect(
            DeepSeekPoWSolver.hashHex("test_prefix_")
                == "f6ad5f4df80965c062ddf7943438fe904353ea60442c4ba3462ad486c5df4331"
        )
        #expect(
            DeepSeekPoWSolver.hashHex("test_prefix_0")
                == "7d3773f32ca59f8c6102d6fa3ad2a359098f1e7a5516355e159e0b7a860a3543"
        )
        let answer = DeepSeekPoWSolver.solve(
            challenge: "62a0bbf8fc67c687757131fae1591adeeaff9bffd154d45613ace09bdb36d0dc",
            salt: "1943de5b136bcbe66179",
            expireAt: 1_795_108_916_750,
            difficulty: 144_000
        )
        #expect(answer == 65_120)
    }

    @Test("DeepSeek R1 真实流：THINK 快照 → 省略 p 的连续增量 → 切换到 RESPONSE 不重不漏")
    func deepSeekR1RealStreamSequence() {
        var extractor = WebDeltaExtractor(mode: .sseDeepSeek)
        let frames = [
            #"{"v":{"response":{"fragments":[{"id":2,"type":"THINK","content":"我们需要"}]}}}"#,
            #"{"p":"response/fragments/-1/content","o":"APPEND","v":"回答"}"#,
            #"{"v":"两个字"}"#,
            #"{"p":"response/fragments/-1/elapsed_secs","o":"SET","v":0.38}"#,
            #"{"p":"response/fragments","v":[{"id":2,"type":"THINK","content":"我们需要回答两个字"},{"id":3,"type":"RESPONSE","content":"收"}]}"#,
            #"{"p":"response/fragments/-1/content","o":"APPEND","v":"到"}"#,
            #"{"v":"！"}"#,
            #"{"p":"response","o":"BATCH","v":[{"p":"accumulated_token_usage","v":64},{"p":"quasi_status","v":"FINISHED"}]}"#
        ]
        var reasoning = ""
        var answer = ""
        var totalTokens = 0
        for frame in frames {
            for delta in extractor.extract(frame) {
                switch delta {
                case let .reasoning(t): reasoning += t
                case let .content(t): answer += t
                case let .usage(u): totalTokens = u.totalTokens
                case .toolCalls: break
                }
            }
        }
        #expect(reasoning == "我们需要回答两个字")
        #expect(answer == "收到！")
        #expect(totalTokens == 64)
    }

    @Test("支持桌面端 snake_case 格式的渠道 JSON 直接粘贴导入")
    func snakeCaseSpecDecode() throws {
        let raw = """
        {
          "name": "自带账号适配器",
          "chat_url": "https://example.com/api/chat",
          "headers": {"Cookie": "{{cookie}}"},
          "body_template": "{\\"prompt\\":\\"{{prompt}}\\"}",
          "response_mode": "sse_text",
          "stream_path": "data.text",
          "models": ["m1"]
        }
        """
        let spec = try JSONDecoder().decode(WebAdapterSpec.self, from: Data(raw.utf8))
        #expect(spec.chatURL == "https://example.com/api/chat")
        #expect(spec.responseMode == .sseJSONText)
        #expect(spec.streamPath == "data.text")
    }

    @Test("全链路端到端：建会话 → 解算 PoW → 吞空行 SSE 流（模拟 AsyncBytes.lines）")
    func fullStreamHandlesSwallowedBlankLinesAndPoW() async throws {
        final class MockProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let path = request.url?.path ?? ""
                let bodyData: Data
                var contentType = "application/json"
                if path.contains("chat_session/create") {
                    bodyData = Data(#"{"code":0,"data":{"biz_code":0,"biz_data":{"chat_session":{"id":"sess-ok"}}}}"#.utf8)
                } else if path.contains("create_pow_challenge") {
                    let target = DeepSeekPoWSolver.hashHex("testsalt_1700000000_7")
                    let json = """
                    {"code":0,"data":{"biz_code":0,"biz_data":{"challenge":{"algorithm":"DeepSeekHashV1","challenge":"\(target)","salt":"testsalt","signature":"sig1","difficulty":100,"expire_at":1700000000,"target_path":"/api/v0/chat/completion"}}}}
                    """
                    bodyData = Data(json.utf8)
                } else {
                    // 校验请求头确实带上了 x-ds-pow-response
                    let pow = request.value(forHTTPHeaderField: "x-ds-pow-response") ?? ""
                    guard !pow.isEmpty else {
                        bodyData = Data(#"{"code":40300,"msg":"MISSING_HEADER"}"#.utf8)
                        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType])!
                        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: bodyData)
                        client?.urlProtocolDidFinishLoading(self)
                        return
                    }
                    contentType = "text/event-stream; charset=utf-8"
                    let sse = [
                        "event: ready",
                        #"data: {"request_message_id":1,"response_message_id":2}"#,
                        "",
                        "event: update_session",
                        #"data: {"updated_at":1700000001}"#,
                        "",
                        #"data: {"v":{"response":{"fragments":[{"id":2,"type":"RESPONSE","content":"你好"}]}}}"#,
                        "",
                        #"data: {"p":"response/fragments/-1/content","o":"APPEND","v":"，世界"}"#,
                        "",
                        #"data: {"v":"！"}"#,
                        "",
                        "event: title",
                        #"data: {"content":"打招呼"}"#,
                        "",
                        "event: close",
                        #"data: {"click_behavior":"none"}"#
                    ].joined(separator: "\n")
                    bodyData = Data(sse.utf8)
                }
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": contentType]
                )!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: bodyData)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockProtocol.self]
        let mockSession = URLSession(configuration: cfg)
        let client = WebAdapterClient(session: mockSession)

        var text = ""
        let stream = client.stream(
            spec: .deepSeekWeb,
            credential: "valid-token",
            model: "deepseek-chat",
            messages: [ChatMessage(role: .user, content: "hi")]
        )
        for try await delta in stream {
            if case let .content(chunk) = delta {
                text += chunk
            }
        }
        #expect(text == "你好，世界！")
    }

    @Test("豆包 v2 patch_op 与 JSON 字符串 content 增量解析（保留叠字不误吞）")
    func doubaoV2AndJSONDelta() {
        var extractor = WebDeltaExtractor(mode: .sseDoubao)
        let f1Inner = WebAdapterTemplate.jsonEscape(#"{"is_delta":true,"patch_op":[{"patch_value":{"content_block":[{"block_type":10040,"content":{"thinking_block":{"text":"先想"}}}]}}]}"#)
        let f2Inner = WebAdapterTemplate.jsonEscape(#"{"is_delta":true,"message":{"content":"{\"text\":\"哈\"}"}}"#)
        let f3Inner = WebAdapterTemplate.jsonEscape(#"{"is_delta":true,"message":{"content":"{\"text\":\"哈\"}"}}"#)
        #expect(extractor.extract(#"{"event_type":2001,"event_data":"\#(f1Inner)"}"#) == [.reasoning("先想")])
        #expect(extractor.extract(#"{"event_type":2001,"event_data":"\#(f2Inner)"}"#) == [.content("哈")])
        #expect(extractor.extract(#"{"event_type":2001,"event_data":"\#(f3Inner)"}"#) == [.content("哈")])
    }

    @Test("通义千问国内版（qianwen.com）baseline + JSON Patch add 增量解析")
    func qianwenDomesticStream() {
        var extractor = WebDeltaExtractor(mode: .sseQianwen)
        let baseline = #"{"contents":[{"mime_type":"text/plain","content":"收到"}]}"#
        let patch = #"{"contents":[{"mime_type":"text/plain","patch":[{"op":"add","path":"/content","value":"，老板"}]}]}"#
        let finalSnap = #"{"contents":[{"mime_type":"text/plain","content":"收到，老板"}]}"#
        #expect(extractor.extract(baseline) == [.content("收到")])
        #expect(extractor.extract(patch) == [.content("，老板")])
        #expect(extractor.extract(finalSnap) == [])
    }

    @Test("千问 4.15+ 真机回包：正文在 multi_load/iframe 的 content 快照里，进度/卡片帧不产出文本")
    func qianwenMultiLoadContentSnapshots() {
        var extractor = WebDeltaExtractor(mode: .sseQianwen)
        func frame(_ mime: String, _ status: String, _ content: String = "") -> String {
            #"{"error_msg":"","data":{"messages":[{"mime_type":"\#(mime)","meta_data":{"multi_load":[]},"content":"\#(content)","status":"\#(status)"}]},"error_code":0,"communication":{"resid":1}}"#
        }
        #expect(extractor.extract(frame("signal/post", "complete")) == [])
        #expect(extractor.extract(frame("bar/progress", "processing")) == [])
        #expect(extractor.extract(frame("multi_load/iframe", "processing", "西湖位于")) == [.content("西湖位于")])
        #expect(extractor.extract(frame("multi_load/iframe", "processing", "西湖位于杭州")) == [.content("杭州")])
        #expect(extractor.extract(frame("multi_load/iframe", "complete", "西湖位于杭州")) == [])
        #expect(extractor.extract(frame("survey/card", "complete")) == [])
        #expect(WebAdapterClient.errorEnvelope(from: ["error_msg": "", "error_code": 0, "data": [:] as [String: Any]]) == nil)
        let punish: [String: Any] = [
            "ret": ["FAIL_SYS_USER_VALIDATE", "RGV587_ERROR::SM::哎哟喂,被挤爆啦,请稍后重试"],
            "data": ["url": "https://chat2.qianwen.com:443//api/v2/chat/_____tmd_____/punish?x5secdata=x"]
        ]
        let hint = WebAdapterClient.errorEnvelope(from: punish)
        #expect(hint?.contains("人机验证") == true)
        #expect(hint?.contains("被挤爆啦") == true)
    }

    @Test("豆包多行与带引号提示词经双层 JSON 转义后内外层均可合法反序列化")
    func doubaoMultilineNestedJSONValid() throws {
        let client = WebAdapterClient()
        let messages = [
            ChatMessage(role: .system, content: "第一行要求\n第二行\"带引号\"要求"),
            ChatMessage(role: .user, content: "你好\n请回答")
        ]
        let req = try client.makeRequest(
            spec: .doubaoWeb,
            credential: "sess123",
            model: "doubao-seed-1.6",
            messages: messages
        )
        let body = try #require(req.httpBody)
        let outer = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let msgArr = try #require(outer["messages"] as? [[String: Any]])
        let innerStr = try #require(msgArr.first?["content"] as? String)
        let innerObj = try #require(try JSONSerialization.jsonObject(with: Data(innerStr.utf8)) as? [String: Any])
        let text = try #require(innerObj["text"] as? String)
        #expect(text.contains("第一行要求\n第二行\"带引号\"要求"))
        #expect(text.contains("你好\n请回答"))
    }
}
