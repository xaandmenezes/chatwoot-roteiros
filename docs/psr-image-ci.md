# Build, homologação e deploy da imagem PSR

O GitHub mantém os checks de código. PRs PSR para `develop` e `prod` e pushes em `develop` seguem sem build ou publicação da imagem PSR. O workflow upstream **Test Docker Build** continua disponível para PRs com base `master` e por execução manual. Se houver proteção de branch que exija um dos checks de imagem removidos, o administrador deve retirar essa exigência e manter os checks de código.

Use o SHA completo do head do PR de release revisado. Se o head mudar, homologue o novo SHA. Para hotfix, use o head do PR de hotfix. Registre na issue o SHA, o ID Docker `sha256:…`, o SHA-256 do arquivo, o local de armazenamento e o resultado do smoke.

## 1. Escolha onde construir

Use Git, Bash, OpenSSL, `shasum`, Docker com Buildx e Compose com suporte a `up --wait`. Confira com `docker context show`, `docker version`, `docker compose version`, `docker buildx version` e `docker system df`. Reserve espaço para checkout, cache, imagem e arquivo. Use o contexto local do host escolhido. Os comandos abaixo criam um builder dedicado e o removem ao final, inclusive em caso de falha.

- **VPS.** Confira `free -h`, `df -h` e a carga dos serviços. Exemplo para uma janela em que o host pode ceder 6 GiB e dois CPUs ao builder: `export PSR_BUILD_MEMORY=6g PSR_BUILD_CPU_QUOTA=200000`. Mantenha folga para o SO, o Chatwoot e o armazenamento da imagem. Se o host estiver pressionado, use outro ambiente ou outra janela.
- **Mac de 8 GB.** Use um runtime Docker local com emulação `linux/amd64` em Apple Silicon. Configure a VM com memória suficiente para o builder e folga para o macOS. Exemplo com VM de 5 GiB: `export PSR_BUILD_MEMORY=4g PSR_BUILD_CPU_QUOTA=200000 PSR_NODE_HEAP=3072`. Se a compilação ou a emulação exceder a capacidade disponível, use a VPS. Esses valores são pontos de partida para medir no host. [Limites do driver Docker Container](https://docs.docker.com/build/builders/drivers/docker-container/).

## 2. Gere o arquivo da release

Em Bash, na raiz de um clone do repositório, defina `REVISION` com o SHA completo e `ARTIFACT_ROOT` com um diretório persistente fora do checkout. Busque a branch de origem do PR antes de executar o bloco. Use um único operador por SHA e host.

```bash
(
  set -euo pipefail
  : "${REVISION:?Defina o SHA completo}" "${ARTIFACT_ROOT:?Defina o diretório de artefatos}"
  : "${PSR_BUILD_MEMORY:?Defina o limite de memória}" "${PSR_BUILD_CPU_QUOTA:?Defina a cota de CPU}"
  [[ "$REVISION" =~ ^[0-9a-f]{40}$ ]]
  source_repo=$(git rev-parse --show-toplevel)
  image="chatwoot-psr:$REVISION"
  docker info >/dev/null
  if docker image inspect "$image" >/dev/null 2>&1; then
    printf 'A tag %s já existe. Recupere o artefato correspondente antes de continuar.\n' "$image" >&2
    exit 1
  fi

  staging=$(mktemp -d)
  builder="psr-build-$(openssl rand -hex 8)"
  trap 'docker buildx rm "$builder" >/dev/null 2>&1 || :; rm -rf -- "$staging"' EXIT
  git init -q "$staging/source"
  git -C "$staging/source" fetch --depth=1 "$source_repo" "$REVISION"
  git -C "$staging/source" checkout --detach FETCH_HEAD
  test "$(git -C "$staging/source" rev-parse HEAD)" = "$REVISION"

  printf '[worker.oci]\n  max-parallelism = 2\n' > "$staging/buildkitd.toml"
  docker buildx create --name "$builder" --driver docker-container \
    --driver-opt "memory=$PSR_BUILD_MEMORY,memory-swap=$PSR_BUILD_MEMORY,cpu-quota=$PSR_BUILD_CPU_QUOTA,cpu-period=100000" \
    --buildkitd-config "$staging/buildkitd.toml"
  docker buildx build --builder "$builder" --platform linux/amd64 --load \
    --file "$staging/source/docker/Dockerfile" \
    --build-arg "NODE_OPTIONS=--max-old-space-size=${PSR_NODE_HEAP:-4096} --openssl-legacy-provider" \
    --label "org.opencontainers.image.revision=$REVISION" \
    --tag "$image" "$staging/source"
  docker buildx rm "$builder"

  umask 077
  mkdir -p "$ARTIFACT_ROOT"
  artifact=$(mktemp -d "$ARTIFACT_ROOT/$REVISION.XXXXXX")
  printf '%s\n' "$REVISION" > "$artifact/git-sha"
  docker image inspect --format '{{.Id}}' "$image" > "$artifact/image-id"
  docker image save -o "$artifact/image.tar" "$image"
  (cd "$artifact" && shasum -a 256 image.tar > image.tar.sha256)
  printf 'Artefato salvo em %s\n' "$artifact"
)
```

O clone temporário contém o `.git` usado pelo Dockerfile para gerar `/app/.git_sha`. A tag usa o SHA Git. O ID Docker identifica a imagem e o checksum confirma os bytes do arquivo transportado. Guarde a pasta em armazenamento autorizado e persistente. Se o build carregou a tag mas a gravação do arquivo falhou, repita apenas a seção de gravação após conferir a identidade da imagem. [Exportação local com Buildx](https://docs.docker.com/reference/cli/docker/buildx/build/).

## 3. Carregue e homologue o arquivo

Defina `ARTIFACT_DIR` com a pasta gerada. Se o build foi feito no Mac, copie a pasta inteira por SSH para o host autorizado. Use o mesmo bloco de conferência e carga no host de homologação e no Docker Engine em que o Dokploy vai ativar a imagem. Compare os três registros com a evidência da release ao receber a pasta.

```bash
(
  set -euo pipefail
  cd "${ARTIFACT_DIR:?Defina a pasta do artefato}"
  shasum -a 256 -c image.tar.sha256
  revision=$(cat git-sha)
  image_id=$(cat image-id)
  [[ "$revision" =~ ^[0-9a-f]{40}$ && "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]]
  tag="chatwoot-psr:$revision"
  docker info >/dev/null
  if existing_id=$(docker image inspect --format '{{.Id}}' "$tag" 2>/dev/null); then
    test "$existing_id" = "$image_id"
  fi
  docker image load -i image.tar
  test "$(docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$tag")" = "$image_id linux/amd64"
)
```

No host autorizado para homologação, busque o SHA da release no checkout com este roteiro e execute:

```bash
docker/psr-image-smoke.sh "$(cat "$ARTIFACT_DIR/git-sha")" "$(cat "$ARTIFACT_DIR/image-id")"
```

O smoke confere a revisão OCI, `/app/.git_sha` e o manifesto do Vite. O projeto Compose tem nome aleatório, rede interna, volumes descartáveis, credenciais próprias e nenhuma porta publicada. Usa o Compose do Dokploy do SHA da release, prepara um PostgreSQL novo, testa `/health`, aguarda registro do Sidekiq no Redis e confirma o ID Docker de `prepare`, `rails` e `sidekiq`. Ao sair, remove os contêineres e volumes daquele projeto. Em caso de erro, preserve o diagnóstico e registre a falha antes de prosseguir.

## 4. Ative no Dokploy

Antes do merge em `prod`, obtenha autorização, confirme revisão e checks e registre o smoke aprovado. Confirme o artefato anterior, seu ID e o SHA do Compose anterior. Para a primeira transição, preserve a imagem atualmente em execução com `docker image save` e registre sua tag, SHA, ID e checksum. Verifique a rota de restauração do banco e do storage antes de aplicar migrações.

No Dokploy, use implantação manual no projeto Docker Compose existente. Confirme que PostgreSQL e Redis já estão disponíveis no mesmo Docker Engine. Aponte a origem para a revisão de Compose aprovada para a release e defina `CHATWOOT_IMAGE_TAG` com o SHA Git da imagem homologada. No comando personalizado, preserve o nome do projeto e o caminho Compose do comando padrão exibido pelo Dokploy e use a forma abaixo, substituindo os valores:

```text
compose -p PROJETO_ATUAL -f CAMINHO_COMPOSE_ATUAL up -d --no-build --pull never
```

O Dokploy acrescenta `docker` ao comando. Confirme que a implantação automática e a opção de baixar imagens antes do deploy estão desativadas para esse projeto. Preserve os volumes, nomes e demais opções de roteamento do projeto. [Comando personalizado no Dokploy](https://docs.dokploy.com/docs/core/docker-compose).

Após o deploy, no Docker Engine do Dokploy, use o projeto e caminho reais para obter os IDs dos contêineres e conferir o resultado. Execute com o ambiente da implantação disponível ao Compose:

```bash
docker compose -p "$PROJECT" -f "$COMPOSE_PATH" ps -a
for service in prepare rails sidekiq; do
  container=$(docker compose -p "$PROJECT" -f "$COMPOSE_PATH" ps -a -q "$service")
  docker inspect --format '{{.Image}} {{.State.Status}} {{.State.ExitCode}} {{.RestartCount}}' "$container"
done
docker compose -p "$PROJECT" -f "$COMPOSE_PATH" logs --tail=100 sidekiq
curl --fail --silent --show-error "$FRONTEND_URL/health"
```

Confirme o ID esperado nos três serviços, a finalização de `prepare` com código zero, o Rails saudável, o painel acessível e o Sidekiq processando na fila existente. Registre a versão ativa e os resultados na issue.

## 5. Volte para a versão anterior

Confira o checksum e carregue o arquivo anterior com o bloco da seção 3. Confirme que o schema e os dados atuais são compatíveis com a versão anterior. Se a migração exigir restauração, siga o procedimento de recuperação aprovado para banco e storage antes de reativar a imagem. Volte o Dokploy para a revisão anterior do Compose e o valor anterior de `CHATWOOT_IMAGE_TAG`. Rode a mesma implantação manual com `--no-build --pull never`, repita as verificações da seção 4 com o ID anterior e registre o resultado. Preserve os volumes durante a troca de imagem.
