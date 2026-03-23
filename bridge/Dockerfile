FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bridge .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=builder /bridge /bridge
EXPOSE 9090
ENTRYPOINT ["/bridge"]
