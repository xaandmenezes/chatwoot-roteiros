# Ativos da marca Porto Seguro Roteiros

A identidade do painel de atendimento usa como referência o site oficial da Porto Seguro Roteiros. [Site oficial](https://www.portoseguroroteiros.com.br/)

## Origem e variantes

| Ativo em `public/brand-assets/psr/` | Origem e uso |
| --- | --- |
| `logo.png` | Logo horizontal do cabeçalho do site, rasterizado a 495 × 120 px. Usado em superfícies claras, inclusive o cabeçalho de e-mail. [Arquivo no site](https://www.portoseguroroteiros.com.br/assets/LOGOPSR-7bf1f878.svg) · [Fonte no repositório](https://github.com/alencarfreire/psr-site/blob/8e7ea30002df71d820a8a82d064fd3ad2d1157e8/app/assets/images/LOGOPSR.svg) |
| `logo-dark.png` | Variante de 495 × 120 px derivada do mesmo arquivo. Mantém as formas e clareia os tons turquesa, marrom e cinza para leitura em fundo escuro. |
| `favicon-{16x16,32x32,96x96}.png`, `icon-{180,192,512}.png` | Derivados do símbolo usado como favicon no site. O arquivo de 512 × 512 px também é a miniatura da marca. [Arquivo no site](https://www.portoseguroroteiros.com.br/icon.svg) · [Fonte no repositório](https://github.com/alencarfreire/psr-site/blob/8e7ea30002df71d820a8a82d064fd3ad2d1157e8/public/icon.svg) |
| `favicon-badge-{16x16,32x32,96x96}.png` | Versões do favicon com um ponto de notificação vermelho com contorno branco, conforme o comportamento de alerta da aba no Chatwoot. |

Os PNGs foram renderizados com `rsvg-convert`. A variante escura troca `#2c8c99` por `#7dd1da`, `#2c8c9a` por `#54afbc`, `#5a3403` por `#e6ac65` e `#3d3d3d` por `#e5e9e9` antes da renderização. As versões com notificação usam ImageMagick para desenhar o círculo e o contorno antes de reduzir a imagem ao tamanho final.

A arte da marca vem da Porto Seguro Roteiros e é usada neste fork para identificar seu atendimento. O site identifica a marca com aviso de direitos reservados. O SVG do favicon contém créditos a [RealFaviconGenerator](https://realfavicongenerator.net/). Os arquivos de licença e avisos do Chatwoot e os ativos padrão permanecem nas localizações originais. [Licença do Chatwoot neste fork](../LICENSE) · [Site oficial](https://www.portoseguroroteiros.com.br/)

## Cores de referência

A folha de estilos do site define turquesa `#2a7a84`, petróleo escuro `#1c2e32`, superfície clara `#f5fafa` e laranja `#e08a2e`. [Paleta do site](https://github.com/alencarfreire/psr-site/blob/a6ff437ea1e50cf31c9ab1011bfe18ff5f8d5147/app/assets/tailwind/application.css#L50-L58)

| Par | Contraste sRGB |
| --- | ---: |
| Branco `#ffffff` e turquesa `#2a7a84` | 4,98:1 |
| Turquesa `#2a7a84` e superfície clara `#f5fafa` | 4,73:1 |
| Petróleo `#1c2e32` e superfície clara `#f5fafa` | 13,41:1 |
| Petróleo `#1c2e32` e laranja `#e08a2e` | 5,28:1 |
| Turquesa claro `#7dd1da` e fundo escuro do painel `#1c1d20` | 9,63:1 |

A variante de interação usa o turquesa `#2a727b`, que mantém o texto branco com contraste de 5,54:1 em repouso e 4,77:1 ao passar o cursor ou focar o botão.

## Aplicação no fork

O painel e os e-mails aplicam os padrões PSR ao ler as configurações da instalação. Uma instalação atualizada e uma nova usam os mesmos ativos da imagem. Valores personalizados de nome, logo e URL continuam tendo precedência. O widget e a central de ajuda leem as configurações originais. O editor de marca do Super Admin continua sujeito às regras da edição instalada. [Implementação](../lib/psr/branding.rb) · [Licença da edição Enterprise](../enterprise/LICENSE)

Nos e-mails, o logo usa o endereço do painel em `FRONTEND_URL`. O rodapé da marca aponta para o site oficial. Os links de recuperação de senha, confirmação e preferências apontam para o painel. Templates personalizados por conta ou instalação continuam tendo precedência sobre os arquivos da imagem.

No Dokploy, configure `MAILER_SENDER_EMAIL` com o nome **Porto Seguro Roteiros** e a caixa autorizada pelo provedor. Por exemplo, `Porto Seguro Roteiros <atendimento@example.org>` ilustra o formato. Rails e Sidekiq recebem o mesmo remetente e as variáveis SMTP definidas para a implantação. As caixas de entrada mantêm suas regras de envio e resposta. [Compose do Dokploy](../docker-compose.dokploy.yml)

Para conferir uma atualização em homologação, abra o login em tema claro e escuro, entre como agente e verifique o nome da aba, o logo e o indicador de mensagens. Gere um e-mail de teste para uma caixa controlada e confira o campo De, o carregamento do logo e o destino dos links. A entrega real depende da configuração do provedor de e-mail.
