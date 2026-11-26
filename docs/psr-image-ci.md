# Homologação e publicação da imagem PSR

Ao abrir, reabrir ou atualizar um PR, **Deploy Check → Check Deployment** constrói a imagem para o SHA da branch de origem em um runner descartável. Em um PR deste repositório para `prod`, a etiqueta `verify-psr-image` permite repetir o check em **Actions → Verify PSR image by digest**. Se a etiqueta já estiver presente, remova-a e aplique-a novamente.

Os checks usam o Dockerfile de produção para `linux/amd64` e baixam o resultado pelo digest a partir do registry local do runner. O Compose do Dokploy prepara um banco novo, sobe o Rails e o Sidekiq com a imagem baixada e usa PostgreSQL e Redis isolados. O check valida o HTTP 200 com `woot` em `/health`, o heartbeat do Sidekiq no Redis e o ID da imagem dos dois contêineres. Consulte o resumo da execução para ver o SHA e o digest. O registry local desaparece ao final do job.

## Publicação no GHCR

No repositório `xaandmenezes/chatwoot-roteiros`, cada push em `develop` executa **Publish verified PSR image**. O workflow repete a homologação para o SHA do push. Se ela passar, usa o `GITHUB_TOKEN` do job para copiar o manifesto ou índice OCI completo para `ghcr.io/xaandmenezes/chatwoot-roteiros:<SHA completo>`. Em seguida, confirma o digest da tag, confere o hash do manifesto publicado e baixa a imagem do GHCR por digest. A referência `ghcr.io/xaandmenezes/chatwoot-roteiros@sha256:…` aparece no resumo da execução.

A publicação usa somente a tag do SHA e recusa sobrescrevê-la com um digest diferente. Uma nova compilação do mesmo SHA pode gerar outro digest, pois o Dockerfile consome pacotes e imagens-base atualizáveis. Consulte a execução que publicou a tag para obter o digest já homologado.

Os checks de PR têm token somente de leitura e usam apenas o registry descartável. Os workflows de publicação do Chatwoot CE e EE no Docker Hub rodam somente em `chatwoot/chatwoot`.

## Uso na release

Abra o PR de `develop` para `prod` com as issues incluídas e o responsável. No resumo de **Publish verified PSR image**, confirme que o SHA publicado corresponde ao head atual do PR e registre a referência completa por digest. Obtenha autorização de deploy e verifique a disponibilidade da imagem anterior para rollback antes do merge.

O deploy é uma etapa separada. O host de produção precisa de acesso de leitura para baixar a imagem homologada pelo digest antes de ativá-la no Dokploy, que executa o Compose com `--pull never`. Após o deploy, confira a versão ativa, a saúde do painel e o processamento do Sidekiq. Registre o digest e os resultados na issue da release.
