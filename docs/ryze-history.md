# Provisionamento do histórico Ryze

No piloto (`RYZE_DIRECT_INBOX_ENABLED=false`), o histórico continua restrito à conversa e ao JID configurados em `RYZE_EDIT_CONVERSATION_ID` e `RYZE_PILOT_CHAT_JID`. No modo direto, um JID legado, mesmo válido, **não autoriza** acesso ao histórico.

No modo direto configure `RYZE_HISTORY_BINDING_SECRET` no ambiente dos processos Rails e da tarefa. Use uma chave aleatória exclusiva da instalação (por exemplo, gerada com `openssl rand -hex 32`); não a registre em código, ticket ou log. Sem segredo, o histórico direto fica desabilitado. Rotacioná-lo invalida todos os atestados anteriores: revalide cada vínculo antes de emitir outro.

Bloquear a escrita pela API protege vínculos **novos**, mas não separa valores legítimos de valores que os clientes já podiam ter gravado. Um marcador booleano na mesma coluna também poderia ter sido preenchido antes da atualização. Por isso a operação assina o vínculo com HMAC-SHA256; nem um JID legado nem uma assinatura copiada de outra conversa bastam.

1. Crie a conversa pela API sem `whatsapp_jid`. Na caixa Ryze direta, esse campo e as chaves `ryze_*` são reservados ao servidor.
2. Um operador autorizado deve confirmar a conta, a caixa, a conversa (ID visível no painel) e o destinatário na instância Ryze por uma fonte independente. **Não** use o valor de `additional_attributes` ou a alegação do cliente como prova.
3. No runtime Rails da instalação, execute `bundle exec rake 'ryze:bind_history[ACCOUNT_ID,DISPLAY_ID,JID_CONFIRMADO]'`. A tarefa grava o JID e a assinatura. Ela cobre instância, conta, caixa, contato, associação contato–caixa, ID interno, ID visível, UUID da conversa e JID. Recriação ou alteração desses campos exige nova conferência e atestado. Reabrir a mesma conversa ou mudar seu status sem alterar a identidade não exige reatestar. A tarefa recusa uma caixa diferente ou conflito com o JID existente: investigue a divergência, não migre vínculos em massa.
4. Com `RYZE_HISTORY_SYNC_ENABLED` habilitada, o botão aparece depois de esgotar o histórico local. Para suspender as importações, defina `RYZE_HISTORY_SYNC_ENABLED=false` no ambiente de execução; isso não remove mensagens já importadas.

### Mídia pendente

Cada importação faz até quatro tentativas de download. Uma mídia adiada ou indisponível fica marcada na própria mensagem. O agente pode repetir o download pelo botão junto à mensagem, inclusive depois da última página e após recarregar o painel. A ação tenta apenas aquela mídia; não busca outra página nem inicia retentativas em segundo plano.

O reparo atualiza a mensagem no painel sem publicá-la no webhook da caixa, em uma assinatura de conta com a mesma URL ou no socket do usuário configurado como ponte. Se o agente usa a identidade da ponte, o painel que solicitou o reparo recebe a atualização na própria resposta HTTP.

Quando o provedor informa `mediaSize`, o número de bytes decodificados deve coincidir exatamente. Se divergir, o arquivo não é anexado e a ação continua disponível. A tentativa passa quando o provedor devolver o arquivo com o tamanho declarado. Se a divergência persistir, valide o contrato do provedor; não force a aceitação do arquivo. Arquivos declarados acima do limite de 15 MiB não são oferecidos para download.
