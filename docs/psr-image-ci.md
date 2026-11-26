# Homologar a imagem Chatwoot PSR por digest

Abra o PR de release de `develop` para `prod`, listando as issues e o responsável. Antes do merge, obtenha autorização de deploy. Confira o SHA do PR e as mudanças no Dockerfile, no Compose e no workflow. Com permissão para gerenciar etiquetas, aplique `verify-psr-image` ao PR. A execução usa o commit que estava na ponta da branch quando a etiqueta foi aplicada. Para homologar um novo commit, remova e reaplique a etiqueta.

Abra **Actions → Verify PSR image by digest** e selecione a execução pelo número do PR e pelo SHA completo. O resumo de uma execução bem-sucedida identifica o commit, a arquitetura e o digest. O log de build registra o push. A etapa seguinte faz o pull pelo digest e confere a revisão OCI, o arquivo `/app/.git_sha` e o manifesto de assets.

A homologação usa o Dockerfile de produção e o Compose do Dokploy em um runner GitHub descartável. O Compose prepara um banco novo e inicia o Rails com a imagem baixada, usando PostgreSQL e Redis isolados. O check aguarda a resposta HTTP 200 com `woot` em `/health` e compara o ID da imagem do contêiner saudável com o da imagem baixada.

O registry escuta em `127.0.0.1:5000` no runner e desaparece ao final do job. O digest registrado identifica a imagem daquela execução. Distribuir essa mesma imagem para outro ambiente requer preservá-la em um registry autorizado. Uma nova compilação pode gerar outro digest, pois o Dockerfile também consome pacotes e imagens-base atualizáveis.

Antes de publicar, preserve a imagem verificada em um registry autorizado e referencie seu digest para publicar exatamente a imagem testada. Após o deploy, confira a versão ativa, a saúde do painel e o processamento do Sidekiq; registre o digest e os resultados. O registry efêmero deste workflow não fornece essa distribuição.
