FROM golang:1.26-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o send-notification .

FROM alpine:latest
WORKDIR /app
COPY --from=build /app/send-notification .
CMD ["./send-notification"]