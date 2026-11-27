# Build e deploy da imagem PSR

PRs para `develop`, pushes em `develop` e PRs para `prod` seguem **sem build de imagem**.

## Publicação automática no GHCR

- Ao fazer merge em `prod` (ou disparar manualmente **Actions → Release PSR image**), o workflow [.github/workflows/release_psr_image.yml](../.github/workflows/release_psr_image.yml) constrói a imagem `linux/amd64` usando cache do GitHub Actions (`type=gha`) e publica no GHCR:
  - `ghcr.io/xaandmenezes/chatwoot-roteiros:<SHA completo>`
  - `ghcr.io/xaandmenezes/chatwoot-roteiros:prod` (quando o evento for push em `prod`)
- Quando `Gemfile.lock` e `package.json`/`pnpm-lock.yaml` não mudam, as camadas de gems e dependências JS vêm do cache e o workflow gera apenas os assets e a imagem final.

## Deploy e rollback no Dokploy

- O [docker-compose.dokploy.yml](../docker-compose.dokploy.yml) usa `ghcr.io/xaandmenezes/chatwoot-roteiros:${CHATWOOT_IMAGE_TAG:-prod}` com `pull_policy: always` e não possui bloco `build`, evitando compilação na VPS ou no Mac.
- Por padrão, o deploy puxa a tag `:prod`.
- Para fixar uma versão ou fazer rollback, defina `CHATWOOT_IMAGE_TAG=<SHA completo anterior>` nas variáveis de ambiente do Dokploy e reimplante.
- Após o deploy, confira a versão ativa, `/health` do Rails e o processamento do Sidekiq.
