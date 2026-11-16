# Meridian task server — zero dependencies.
FROM node:22-alpine

ENV NODE_ENV=production \
    MERIDIAN_PORT=8787 \
    MERIDIAN_HOST=0.0.0.0 \
    MERIDIAN_DATA=/data/data.json

WORKDIR /app

COPY package.json meridian-server.mjs ./

RUN mkdir -p /data && chown -R node:node /app /data

USER node

EXPOSE 8787
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.MERIDIAN_PORT||8787)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "meridian-server.mjs"]
