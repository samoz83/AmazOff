env CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=5 \
  go build -trimpath -ldflags="-s -w" -o mitm ./...

Debug proxy, not shipped in the IPK. On the TV: press Start, run `mitm /tmp/patcher/logs` (listens on :8998, exits after 5 minutes), then copy `default_config_debug.json` over the Amazon app's `default_config.json`. Stop restores the original config.

`default_config_debug.json` sets `disable-ssl-cert`, which turns off TLS checks for every connection the Amazon app makes. Use it only on a trusted network, and press Stop when you are done.
