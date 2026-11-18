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

    @Test("没有凭据时直接报错，不会发出请求")
    func requestRejectsEmptyCredential() {
        let client = WebAdapterClient()
        #expect(throws: WebAdapterError.missingCredential) {
            _ = try client.makeRequest(
                spec: .deepSeekWeb, credential: "   ", model: "deepseek-chat", messages: []
            )
        }
    }
}
