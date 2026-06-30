FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o /send-notification .

FROM scratch AS runtime
WORKDIR /app
COPY --from=build /send-notification /send-notification
ENTRYPOINT ["/send-notification"]