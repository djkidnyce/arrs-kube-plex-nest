# Network notes (example)

Copy this to `network-notes.local.md` and fill in your real values. The
`*.local.md` pattern is gitignored, so your actual addresses never reach GitHub.

    cp network-notes.example.md network-notes.local.md

## Cluster
- Node IP(s): 10.0.0.10 (LAN), 10.10.0.10 (storage)
- Pod CIDR: 10.244.0.0/16
- MetalLB / NodePort range: 10.0.0.200-220 / 30000-32767

## NAS
- SMB host: 10.0.0.20  share: media

## Reachable targets on other subnets
- Example service: 192.168.x.x:port  (reached via node default gateway 10.0.0.1)
  Verify: kubectl exec -n media deploy/<app> -- curl -m5 http://<ip>:<port>
  Node route check: ip route get <ip>

## Notes
- Chart values that reference the network (e.g. vpn.firewallOutboundSubnets,
  sabnzbd.config.hostWhitelist) go in my-values.yaml, which is also gitignored.
