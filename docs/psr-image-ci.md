# Validar a imagem de um PR com o Compose do Dokploy

Ao abrir, reabrir ou atualizar um PR, o GitHub Actions executa **Deploy Check → Check Deployment** para o commit da branch de origem. Consulte o resumo da execução para ver o SHA e o digest da imagem validada. O teste roda em um runner descartável e não publica uma versão na VPS.

Abra o PR de release de `develop` para `prod` com as issues incluídas e o responsável. Confira o SHA, as mudanças no Dockerfile, no Compose e no workflow, e obtenha autorização de deploy antes do merge.

Em um PR deste repositório para `prod`, a etiqueta `verify-psr-image` permite repetir a homologação do commit atual. Abra **Actions → Verify PSR image by digest** para consultar essa execução. Se a etiqueta já estiver presente, remova-a e aplique-a novamente para repetir o teste.

A homologação usa o Dockerfile de produção e o Compose do Dokploy em um runner GitHub descartável. O Compose prepara um banco novo e inicia o Rails com a imagem baixada, usando PostgreSQL e Redis isolados. O check aguarda a resposta HTTP 200 com `woot` em `/health` e compara o ID da imagem do contêiner saudável com o da imagem baixada.

O registry escuta em `127.0.0.1:5000` no runner e desaparece ao final do job. O digest registrado identifica a imagem daquela execução. Distribuir essa mesma imagem para outro ambiente requer preservá-la em um registry autorizado. Uma nova compilação pode gerar outro digest, pois o Dockerfile também consome pacotes e imagens-base atualizáveis.

Antes de publicar, preserve a imagem verificada em um registry autorizado e referencie seu digest para publicar exatamente a imagem testada. Após o deploy, confira a versão ativa, a saúde do painel e o processamento do Sidekiq; registre o digest e os resultados. O registry efêmero deste workflow não fornece essa distribuição.
