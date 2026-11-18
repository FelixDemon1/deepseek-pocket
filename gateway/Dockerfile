# syntax=docker/dockerfile:1
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags "-s -w" -o /out/dsggw .

FROM alpine:3.20
RUN adduser -D -u 10001 -h /app gw
WORKDIR /app
COPY --from=build /out/dsggw /usr/local/bin/dsggw
USER gw
EXPOSE 8787
VOLUME ["/app/data"]
ENTRYPOINT ["dsggw", "-config", "/app/config.json"]
