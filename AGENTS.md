<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

# Package manager
Using Bun for package management only install packages with exact version.

# Project Conventions

- Framework: Next.js 16
- Request interception lives in `proxy.ts`
- Do not create `middleware.ts`
