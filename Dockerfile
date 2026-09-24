FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /hashproxy .

FROM alpine:3.20
RUN adduser -D app
USER app
COPY --from=build /hashproxy /hashproxy
EXPOSE 3333
ENTRYPOINT ["/hashproxy"]
