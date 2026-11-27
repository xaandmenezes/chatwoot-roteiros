# Carteira por atendente na caixa Ryze

Na caixa piloto, um atendente lê e responde às conversas individuais atribuídas a ele. Os grupos de WhatsApp ficam disponíveis a todos os membros da caixa. O administrador da conta pode abrir qualquer conversa da conta. O supervisor pode abrir e transferir qualquer conversa da caixa em que recebeu supervisão.

## Preparar o piloto

1. Identifique a caixa de atendimento Ryze do tipo API e confira seus membros em **Configurações → Caixas de entrada**. A conta usada pela ponte Ryze precisa ter autorização para as conversas que processa. Para uma integração que usa a API pública de clientes ou o socket de contato, valide o HMAC com o identificador do contato. No socket, envie também o identificador junto de seu hash.
2. Aplique a migração do banco. Os vínculos existentes começam com supervisão desativada. Faça o inventário no console Rails antes de escolher a data de início. O exemplo retorna somente contagens.

   ```ruby
   inbox = Inbox.find(Integer(ENV.fetch('PSR_RESTRICTED_INBOX_ID')))
   waiting = inbox.conversations.open.unassigned.where(ai_assignee_type: nil)
   groups = Ryze::GroupConversations.scope(inbox.account, inbox_id: inbox.id)
   waiting.where.not(id: groups.select(:id)).group(:team_id).count
   ```

3. Faça a transição em uma janela coordenada. Jobs de socket enfileirados pela versão anterior já contêm a lista antiga de destinatários. Antes de ligar a restrição, suspenda temporariamente os produtores de eventos (incluindo a entrada da ponte, o painel e os agendadores), deixe o Sidekiq escoar a fila `critical` e confirme que não há broadcasts antigos em execução, agendados ou aguardando nova tentativa. Reinicie web e Sidekiq com a mesma configuração antes de reabrir a entrada e as sessões. Aplique o mesmo procedimento se o código já estiver publicado com o piloto desligado.
4. Configure `PSR_RESTRICTED_INBOX_ID` com o ID da caixa nos processos web e Sidekiq. Em **Configurações → Agentes**, edite cada atendente e conceda **Supervisão** aos responsáveis pela fila. A própria conta administrativa continua disponível para essa configuração. Valide com contas de teste antes da ativação em produção.
5. Habilite a atribuição automática da caixa e configure `PSR_RANDOM_ASSIGNMENT_START_AT` em ambos os processos com a data de corte, incluindo o fuso (formato ISO 8601). A data de **criação** define quais conversas entram na fila. As individuais abertas e sem responsável criadas a partir do corte concorrem ao sorteio. Um corte retroativo inclui o estoque do período. As anteriores continuam disponíveis para transferência manual pela supervisão.

A fila começa pelas conversas há mais tempo em espera. A distribuição considera presença, aceite de conversas, equipe e limites aplicáveis. Uma conversa que ficou esperando depois do corte continua elegível, inclusive depois de uma noite sem atendentes. Além do processamento na entrada e na conexão de atendentes, o Sidekiq verifica a fila a cada minuto. Confirme que ele consome as filas `scheduled_jobs` e `default`.

## Homologar

Use duas contas de atendimento na caixa, uma terceira offline e uma conta de supervisão. Abra uma conversa individual sintética, transfira-a entre as duas contas online e mantenha a aba de origem aberta. Confira o histórico e o anexo no destino, o fechamento da conversa na origem e a contagem da fila em ambas as contas. Repita a abertura de um grupo com os dois membros e com um usuário de outra caixa. Revogue a supervisão em uma aba administrativa enquanto a conta de supervisão estiver conectada.

Os links do painel para arquivos da caixa exigem autorização a cada leitura. Arquivos já baixados e respostas anteriormente guardadas por um cache externo têm ciclo de vida próprio. Se houver uma CDN à frente do Active Storage, invalide as respostas antigas da caixa antes do piloto e respeite `Cache-Control: no-store` nas rotas protegidas.

## Pausar ou reverter

Para interromper o sorteio mantendo as carteiras privadas, desative a atribuição automática na caixa. Para voltar à política original de visibilidade, remova as duas variáveis e reinicie web e Sidekiq de maneira coordenada. A política original volta a expor conversas conforme as permissões nativas da caixa. Os responsáveis e os registros de transferência permanecem no banco.
