# Autoria, citação e menção em grupos Ryze

A [PSR-66](https://linear.app/porto-seguro-roteiros/issue/PSR-66) confirmou o trecho citado nos dois sentidos em grupo. Na entrada, o nome do participante veio no corpo da mensagem e o `sender` do Chatwoot apontou para o contato do grupo. Em uma citação de saída, o trecho estava correto, mas o cabeçalho no aparelho dizia “Você” para uma mensagem original da conta comercial. O teste com dois participantes identificáveis ficou pendente.

## Identificadores

| Conceito | API e eventos da Ryze | Caixa API do Chatwoot |
| --- | --- | --- |
| Grupo | `data.chat.type = "group"` e `data.chat.jid` com sufixo `@g.us` no evento `message.exchange`. O endpoint direto de texto recebe esse JID em `number`. | A conversa e o vínculo contato/caixa identificam o destino no webhook. O ensaio usa dois vínculos sintéticos com `source_id` distintos. A documentação da ponte não especifica como ela grava o JID no vínculo. |
| Autor da mensagem | `data.sender.jid`, `data.sender.lid` e `data.sender.name` no evento. O LID pode vir vazio. | Na entrada pela API, o remetente estruturado é o contato da conversa. O painel conserva e mostra o texto com a autoria que a ponte acrescentou. A documentação da ponte não define um campo de participante por mensagem na API do Chatwoot. |
| Mensagem citada | `data.message.context.id` identifica a mensagem original e `data.message.context.sender` informa JID/LID do autor original quando disponíveis. O envio direto usa `replyTo` com o ID original da mesma instância. | O compositor envia `content_attributes.in_reply_to` com o ID local. O backend resolve o ID de transporte pelo `source_id` da mensagem citada na mesma conversa. Na entrada, o ID de transporte também pode ser resolvido para o ID local. |
| Pessoa mencionada | No endpoint direto de texto, `mention` aceita números ou JIDs. A resposta pode retornar `mentions.mentionedUsers`. | Na ponte nativa, o agente digita `@numero`, `@numero@s.whatsapp.net` ou `@id@lid` em mensagem pública de grupo. O webhook preserva o texto literal. A Ryze interpreta a menção e aplica o limite de dez menções individuais por mensagem. O catálogo de eventos não documenta uma lista de mencionados na entrada. |

[Catálogo dos eventos](https://docs.ryzeapi.cloud/pt/api/events/catalog) · [API de texto](https://docs.ryzeapi.cloud/pt/api/messages/text) · [Integração nativa e regras de menção](https://docs.ryzeapi.cloud/pt/api/chatwoot/overview)

A API direta de texto documenta `TokenAccount` ou `TokenInstance` no header `token`. O envio normal pelo painel usa o webhook da caixa provisionada pela ponte. O piloto existente de envio direto do fork aceita chats individuais. Ampliá-lo para grupos criaria outro caminho de envio para uma operação que a ponte já oferece.

## Limites da validação

O teste de requisição usa dois grupos sintéticos e reutiliza deliberadamente um mesmo ID de transporte nos dois para verificar o escopo da resolução da citação. Ele confirma o texto de autoria na leitura do histórico, a referência da mensagem citada e uma entrega ao webhook da caixa por mensagem de saída. A nota interna também gera um webhook, com `private: true`. A entrega externa depende do descarte desse evento pela Ryze. A PSR-66 confirmou a ausência do conteúdo da nota no aparelho e no histórico da Ryze naquele piloto.

Para autoria estruturada, seria preciso confirmar a correspondência entre o evento Ryze, a conversa e a mensagem criada pela ponte, com um contrato de participante por mensagem. Para o cabeçalho “Você”, o ponto a confirmar é a chave de autoria da mensagem citada que a ponte entrega ao WhatsApp. O webhook de saída do Chatwoot contém a referência local e o ID externo, e a conversão para a citação no WhatsApp ocorre na Ryze. A documentação da integração não publica essa conversão. A renderização da menção e a notificação ao membro pertencem igualmente à ponte e ao WhatsApp.

## Piloto mínimo

1. Em uma caixa e instância de teste, use dois grupos novos com JIDs conferidos e dois participantes consentidos. Peça a A e B que enviem textos distintos no grupo A. Peça a B que cite o texto de A. Confira o corpo, a autoria exibida e o alvo da citação no painel. Mantenha o grupo B como controle.
2. Pelo painel, cite a mensagem de A no grupo A e mencione B pela sintaxe documentada. Nos aparelhos dos dois participantes, confira que houve uma única entrega, que o trecho e o cabeçalho correspondem a A e que a menção identifica B. Confira que o grupo B ficou sem entrega.
3. Adicione ao grupo A uma nota interna com a mesma sintaxe de menção e um marcador distinto. Confirme a nota no painel, ausência do marcador nos dois aparelhos e ausência de notificação de menção. Se a autoria da citação divergir, compare `chat.jid`, `sender` e `message.context` no evento, e os IDs de origem e de citação no Chatwoot antes de encaminhar a divergência à Ryze.

## Separar os grupos no painel

A opção `RYZE_GROUPS_INBOX_ENABLED` controla a seção **Grupos de WhatsApp** para a caixa API indicada por `RYZE_INBOX_ID`. O padrão é `false`. Cada conversa conserva seu ID e seu histórico. Para abrir um grupo confirmado, o agente precisa de acesso à caixa piloto e das permissões de conversa do seu perfil, inclusive ao seguir um link antigo. Destinos inconclusivos continuam na fila de atendimento.

Para validar em homologação, anote os totais de um agente para a caixa com os filtros de status e responsável desejados. Defina a opção como `true`, recrie os serviços Rails e Sidekiq e recarregue o painel. Confira se a soma da lista da caixa e da lista de grupos reproduz o total anterior com os mesmos filtros. Abra um grupo por um link antigo e confira o histórico. Repita com um agente sem acesso à caixa e verifique a visibilidade da seção e dos grupos. Quando os contadores de não lidas estiverem ativos, confira um grupo e uma conversa individual com mensagens pendentes.

Para reverter, defina a opção como `false`, aplique a configuração aos dois serviços e recarregue o painel. Os grupos voltam à fila da caixa. A reversão dispensa migração de conversas e limpeza manual do Redis.
