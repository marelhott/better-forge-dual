# Better Forge Dual

Derived image from `madiator2011/better-forge:light` that preserves the original image bootstrap and adds optional dual Forge startup.

Ports:
- `7861/http`: classic Forge via original nginx mapping to internal `7860`
- `7862/http`: UX Forge via added nginx mapping to internal `7862`
- `7777/http`: code-server
- `22/tcp`: SSH

Environment:
- `FORGE_MODE=classic`: start classic Forge only
- `FORGE_MODE=ux`: start UX Forge only
- `FORGE_MODE=both`: start both

Image target:
- `ghcr.io/marelhott/better-forge-dual:light`
