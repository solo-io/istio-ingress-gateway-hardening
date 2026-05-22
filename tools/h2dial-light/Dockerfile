# h2dial-light: minimal HTTP/2 (h2c) client for the Istio Ingress Gateway
# Hardening Playground. Built locally and imported to k3d via `k3d image import`.

FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /h2dial-light main.go

FROM gcr.io/distroless/static-debian12
COPY --from=build /h2dial-light /h2dial-light
ENTRYPOINT ["/h2dial-light"]
