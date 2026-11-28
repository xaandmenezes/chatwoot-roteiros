# PSR-87 — Viari no modal do atendimento

Issue: [PSR-87](https://linear.app/porto-seguro-roteiros/issue/PSR-87). Complementa os PRs Chatwoot #74 e Viari #11 (PSR-86). A mudança parte dos heads desses PRs, sem alterar develop/main diretamente.

## Decisão de produto

O Chatwoot mantém conversa, vínculo de cliente e acompanhamento compacto. O Viari mantém sua interface nativa, cálculos e operações comerciais. Nenhuma operação deve exigir navegar para fora do atendimento. Não copiar formulários de orçamento, OS/reservas ou financeiro no Vue.

- Sidebar: cliente vinculado; seletor de negociação; etapas navegáveis Orçamento, OS, Pagamento; passeios ordenados por agenda, com data e quantidades ADT, CHD, INF, SEN, FREE (incluindo zero), total de PAX; total, pago e saldo da negociação selecionada.
- Modal amplo dentro da conversa: cliente, vínculo/cadastro, orçamento, OS/reserva e pagamento, incluindo remarcação e reembolso pelas regras do Viari. Fechar retorna à mesma conversa; reabrir recupera a seleção.
- Não confundir telefone com identidade permanente do cliente. Sem vínculo confirmado, não exibir dados de outro cadastro; resolver ambiguidade explicitamente.
- Se houver múltiplos orçamentos/OS/reservas, navegar por IDs relacionados, sem misturar registros ou calcular saldo global do cliente como saldo da negociação.
- Preservar preparação de proposta no compositor sem enviar automaticamente.

## Arquitetura e critérios de integração

O Rails mantém autorização por conversa e vínculo privado; Viari continua fonte de verdade. A interface incorporada deve usar a autenticação nativa do Viari, confirmar identidade/empresa do ator mapeado e respeitar permissões. Não expor API key ou segredo, não conceder sessão de usuário com base somente em parâmetros de navegador. Habilitar framing por configuração explícita de origem, apenas nas rotas necessárias. A integração não deve alterar o login ou as permissões nativas dos demais usuários.

O lançamento do modal recebe destino e IDs de recursos validados no servidor. O iframe pode comunicar conclusão ao pai, que deve verificar origem e janela e recarregar o resumo do backend; também recarregar ao fechar. Nunca considerar valores recebidos por mensagens como fonte financeira. Trocar de conversa desmonta o modal e invalida operações/respostas anteriores. O backend continua responsável pela consistência e idempotência.

## Aceite

- Cliente ausente, duplicado, vinculado, cadastro e edição, com permissão/erro visível.
- Múltiplos orçamentos e OS, seleção isolada; retorno às etapas anteriores; os números e categorias PAX batem com o Viari.
- Cotação, confirmação, conversão, reserva, gerenciamento de passageiros, pagamento parcial/total, reembolso, remarcação, cancelamento; atualização do resumo após salvar.
- Mesmo atendimento antes/depois do modal; troca de conversa não reutiliza contexto; indisponibilidade/autenticação insuficiente não produz efeitos ou links externos automáticos.
- Homologação com dois tenants e agentes sintéticos, sem mensagens reais, cobrança ou deploy.

A implementação e o estado de validação devem ser registrados nos PRs e na issue; este documento especifica o resultado esperado e não comprova a homologação.

## Configuração proposta para homologação

Além dos requisitos da PSR-86 (origens Viari, chave de integração, usuário mapeado e segredo de assinatura), configurar no Viari `CHATWOOT_ORIGIN` com a origem exata do Chatwoot e `VIARI_PUBLIC_URL` com a origem pública do Viari. Ambas devem usar HTTPS na implantação; o modal depende de uma sessão normal do Viari no navegador. Preferir origens sob o mesmo site para que a sessão funcione dentro do iframe, sem enfraquecer os atributos dos cookies. A origem deve ser autorizada pelo proxy de produção também, se este aplicar cabeçalhos de framing adicionais. O ticket de lançamento de curta validade vincula o operador, a empresa e a tela solicitada; não concede autenticação. O login do Viari continua obrigatório quando não há sessão válida.

O Rails valida o vínculo antes de emitir consultas ou pedidos de abertura; o Viari valida escopo e permissões no lançamento. A UI não deve usar mensagens do iframe como fonte de valores; busca novamente `resumo_comercial`. O orçamento sem lançamento financeiro ainda não tem saldo/pago efetivos, exibidos como indisponíveis até existir OS ou reserva.
