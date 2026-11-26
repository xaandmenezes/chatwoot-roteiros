# Orquestração de IA da PSR

Projeto: https://linear.app/porto-seguro-roteiros/project/implementacao-chatwoot-roteiros-fe7deb79accd

### Família dos modelos

O OMO Slim inspira a divisão dos papéis. Cada pessoa pode trabalhar no executor da equipe sem instalar o OMO Slim. O usuário escolhe o modelo do chat principal no T3. A preferência atual é Astra High, Fast desligado. A família abaixo governa apenas os papéis delegados.

Leia o valor vigente da linha **Família padrão dos papéis** no projeto do Linear.

Para mudar nesta sessão, diga **“Use a família Claude nos papéis nesta sessão”** (ou Gemini, Codex ou outra disponível). Para mudar o padrão do projeto, edite apenas a linha **Família padrão dos papéis** na descrição do Linear. A instrução explícita da sessão prevalece sobre o padrão. Uma troca de família conserva as responsabilidades, skills, esforço equivalente e Fast nas delegações. Para voltar ao padrão, diga **“Use a família do projeto”**.

Ao delegar, consulte o catálogo real do executor e escolha, na família ativa, um modelo com a capacidade, as ferramentas e a prioridade necessárias. Passe modelo, esforço e Fast explicitamente. Os modelos na tabela são referências para Codex. Se faltar modelo, ferramenta ou Fast, declare a limitação e as opções disponíveis antes de usar outra família ou prioridade. Uma instrução no chat orienta as próximas delegações; o seletor do T3 controla o modelo da conversa principal.

### Papéis e instalação de skills

Acione somente os papéis e as skills úteis à tarefa. A identifica skills do acervo da equipe. B identifica práticas descritas no guia e disponíveis para qualquer pessoa.

| Papel e responsabilidade | Referência Codex | Skills e instalação |
| --- | --- | --- |
| Orchestrator — coordenar, definir aceite e entregar | Astra High no chat | A: `linear-issues`, `git-worktrees`; B: `verification-planning`, `step-back` |
| Explorer — localizar código, rotas e configuração | Luna 6 · baixo | Busca comum com Git e `rg`; A: `systematic-debugging` para rastrear comportamento |
| Fixer — implementar, preparar PR e executar deploy conhecido | Terra 6.1 · médio | A: `git-worktrees`, `tdd-and-testing`, `rails-8-modern` para mudanças Rails |
| Designer — avaliar aparência e interação | Luna 6 · médio | A: `better-interface` |
| Observer — observar e registrar a experiência visual | Luna 6 · médio | A: `webapp-testing` em ambiente local; `yab-browser` quando o usuário indicar o Yab |
| Validator — verificar comportamento, imagem e serviços | Terra 6.1 · alto | A: `tdd-and-testing`, `webapp-testing`; B: `verification-planning` |
| Hunter — diagnosticar falhas silenciosas e reentregas | Sol 6.2 · médio | A: `systematic-debugging`; B: `step-back` quando o defeito voltar |
| Paladin — revisar segurança e permissões | Sol 6.1 · alto | A: `code-review-and-security`, `security-audit` |
| Oracle — resolver dúvida de arquitetura, recuperação ou diagnóstico complexo | Astra · alto | A: `systematic-debugging`, `code-review-and-security`; B: `step-back`. Registre a decisão que motivou a chamada. |
| Proctor — opção futura para avaliar lacunas de cobertura | A definir se ativado | A: `tdd-and-testing`; B: `verification-planning` |

**A · Acervo da equipe.** No Mac da PSR, o diretório de origem é `~/.config/skillshare/skills/<nome>/`. As skills A da tabela foram encontradas também em `~/.agents/skills/`. Em outro ambiente, obtenha o diretório completo da mesma distribuição da equipe, incluindo arquivos auxiliares. Para disponibilizar uma skill no Codex, use o exemplo abaixo trocando o nome. Se já existir um destino, confira sua origem e seu `SKILL.md` antes de reutilizá-lo.

```sh
nome=systematic-debugging
origem="$HOME/.config/skillshare/skills/$nome"
destino="$HOME/.agents/skills/$nome"
test -r "$origem/SKILL.md" && mkdir -p "$HOME/.agents/skills" &&
  test ! -e "$destino" && test ! -L "$destino" && ln -s "$origem" "$destino"
```

**B · Práticas da equipe.** `verification-planning` significa combinar antecipadamente como verificar o resultado; `step-back` significa reavaliar a hipótese quando uma correção falha. Ambas podem ser aplicadas diretamente, sem instalar software.

Ao instalar uma skill do acervo A, confira o `SKILL.md` e a descoberta pelo executor em uma nova sessão. Leia a skill antes de aplicá-la. Em outros provedores, use o diretório de descoberta documentado pelo executor. O acesso ao navegador, às credenciais e ao Linear é verificado separadamente.

### Prompt de inicialização — copie para uma nova conversa

> Inicie o projeto Implementação Chatwoot Roteiros. Localize a raiz com `git rev-parse --show-toplevel`, identifique o repositório, a branch e o worktree. Verifique se o AGENTS.md existe, é legível e está versionado com `git ls-files --error-unmatch -- AGENTS.md`. Leia o arquivo inteiro, as instruções aplicáveis ao diretório da tarefa e as Regras para IA da descrição do projeto. Se faltar o arquivo ou o rastreamento, confira a versão em develop e regularize por PR vinculado ao Linear, preservando instruções locais existentes.
>
> O T3 Code já tem acesso ao Linear pelo MCP. No T3, use a conexão existente para abrir “Implementação Chatwoot Roteiros” pelo UUID `0215754d-519a-40c2-be04-cfca97743aa7` e ler a descrição. Confira o UUID, o nome e a equipe PSR. Ao trabalhar em uma issue, confirme que ela pertence ao projeto. Se o executor estiver sem acesso ao MCP, a alternativa é consultar `project(id: $id) { id name url description teams { nodes { key } } }` com `$id: String!` em `https://api.linear.app/graphql`, usando uma credencial já autorizada e verificando o campo `errors`.
>
> Leia a família padrão no Linear, aplique eventual escolha explícita desta sessão e confira as capacidades do executor e as skills para os papéis necessários. Resuma em poucas linhas o repositório e a branch, a situação do AGENTS.md, o projeto e o meio de acesso, a família efetiva e qualquer pendência. Se o acesso falhar, identifique o bloqueio e prossiga com trabalho local independente. A inicialização usa verificações de leitura; alterações, deploys e testes em produção seguem o escopo da tarefa.
