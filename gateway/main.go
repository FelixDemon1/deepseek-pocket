package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	cfgPath := flag.String("config", "config.json", "配置文件路径")
	flag.Parse()

	cfg, err := LoadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("配置错误: %v", err)
	}
	store, err := OpenStore(cfg.DataFile, cfg.DefaultMonthlyQuota)
	if err != nil {
		log.Fatalf("数据文件错误: %v", err)
	}
	pool := NewUpstreamPool(cfg)
	gw, err := NewGateway(cfg, store, pool)
	if err != nil {
		log.Fatalf("网关初始化失败: %v", err)
	}

	mux := buildMux(gw)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 15 * time.Second,
		// No WriteTimeout: SSE turns stay open until the model finishes.
		IdleTimeout: 120 * time.Second,
	}

	go func() {
		log.Printf("DeepSeek Go gateway 监听 %s，上游 %s，密钥池 %d 个",
			cfg.Listen, cfg.UpstreamBaseURL, len(cfg.UpstreamKeys))
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("监听失败: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	log.Println("已停止")
}

func buildMux(gw *Gateway) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", gw.handleLanding)
	mux.HandleFunc("GET /qr.png", gw.handleQR)
	mux.HandleFunc("GET /healthz", gw.handleHealthz)
	mux.HandleFunc("GET /v1/models", gw.handleModels)
	mux.HandleFunc("GET /v1/me", gw.handleMe)
	mux.HandleFunc("POST /v1/chat/completions", gw.handleChatCompletions)

	mux.HandleFunc("POST /admin/users", gw.adminAuth(gw.handleAdminCreateUser))
	mux.HandleFunc("GET /admin/users", gw.adminAuth(gw.handleAdminListUsers))
	mux.HandleFunc("POST /admin/topup", gw.adminAuth(gw.handleAdminTopUp))
	mux.HandleFunc("POST /admin/toggle", gw.adminAuth(gw.handleAdminToggle))
	mux.HandleFunc("POST /admin/invite", gw.adminAuth(gw.handleAdminInvite))

	mux.HandleFunc("GET /account/status", gw.handleAccountStatus)
	mux.HandleFunc("POST /account/link", gw.handleAccountLink)
	mux.HandleFunc("DELETE /account/link", gw.handleAccountUnlink)
	return mux
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
	})
}
