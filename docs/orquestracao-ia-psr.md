# Orquestração de IA da PSR

Projeto: https://linear.app/porto-seguro-roteiros/project/implementacao-chatwoot-roteiros-fe7deb79accd

### Família dos modelos

Use o perfil OMO Slim `codex-rails` como referência de capacidade. O usuário escolhe o modelo do chat principal no T3. A preferência atual é Astra High, Fast desligado. A família abaixo governa apenas os papéis delegados.

Leia o valor vigente da linha **Família padrão dos papéis** no projeto do Linear.

Para mudar nesta sessão, diga **“Use a família Claude nos papéis nesta sessão”** (ou Gemini, Codex ou outra disponível). Para mudar o padrão do projeto, edite apenas a linha **Família padrão dos papéis** na descrição do Linear. A instrução explícita da sessão prevalece sobre o padrão. Uma troca de família conserva as responsabilidades, skills, esforço equivalente e Fast nas delegações. Para voltar ao padrão, diga **“Use a família do projeto”**.

Ao delegar, consulte o catálogo real do executor e escolha, na família ativa, um modelo com a capacidade, as ferramentas e a prioridade necessárias. Passe modelo, esforço e Fast explicitamente. Os modelos na tabela são referências para Codex. Se faltar modelo, ferramenta ou Fast, declare a limitação e as opções disponíveis antes de usar outra família ou prioridade. Uma instrução no chat orienta as próximas delegações; o seletor do T3 controla o modelo da conversa principal.

### Papéis e instalação de skills

Acione somente os papéis e as skills úteis à tarefa. As letras A e B identificam a origem e o procedimento de instalação logo abaixo.

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

**B · OMO Slim.** No OpenCode com Slim, habilite as skills da tabela no papel do preset. No T3/Codex, instale as que faltarem em um diretório de skills do executor. O exemplo usa o instalador do Codex e uma revisão verificada. Se uma já existir, passe em `--path` apenas a que falta. [Catálogo oficial de skills](https://ohmyopencodeslim.com/skills)

```sh
python3 "$HOME/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py" \
  --repo alvinunreal/oh-my-opencode-slim \
  --ref 22751840b97c9f5d4d4d90530a0d332a2a42088a --method git \
  --path src/skills/verification-planning src/skills/step-back \
  --dest "$HOME/.agents/skills"
```

Depois da instalação, confira o `SKILL.md` e a descoberta pelo executor em uma nova sessão. Leia a skill antes de aplicá-la. Em outros provedores, use o diretório de descoberta documentado pelo executor. O acesso ao navegador, às credenciais e ao Linear é verificado separadamente.

### Prompt de inicialização — copie para uma nova conversa

> Inicie o projeto Implementação Chatwoot Roteiros. Localize a raiz com `git rev-parse --show-toplevel`, identifique o repositório, a branch e o worktree. Verifique se o AGENTS.md existe, é legível e está versionado com `git ls-files --error-unmatch -- AGENTS.md`. Leia o arquivo inteiro, as instruções aplicáveis ao diretório da tarefa e as Regras para IA da descrição do projeto. Se faltar o arquivo ou o rastreamento, confira a versão em develop e regularize por PR vinculado ao Linear, preservando instruções locais existentes.
>
> Faça uma consulta real de leitura do projeto via Linear MCP usando o UUID `0215754d-519a-40c2-be04-cfca97743aa7`. Se o MCP estiver indisponível, use a API GraphQL em `https://api.linear.app/graphql` com credencial autorizada. Consulte `project(id: $id) { id name url description teams { nodes { key } } }` com `$id: String!`. Confira o UUID, o nome, a equipe PSR e a descrição. Pela API, valide também o campo errors. Ao trabalhar em uma issue, confirme que ela pertence a esse projeto. Preserve tokens em segredo.
>
> Leia a família padrão no Linear, aplique eventual escolha explícita desta sessão e confira as capacidades do executor e as skills para os papéis necessários. Resuma em poucas linhas o repositório e a branch, a situação do AGENTS.md, o projeto e o meio de acesso, a família efetiva e qualquer pendência. Se o acesso falhar, identifique o bloqueio e prossiga com trabalho local independente. A inicialização usa verificações de leitura; alterações, deploys e testes em produção seguem o escopo da tarefa.

### Evidência de validação

Antes de alterar um fluxo entre Chatwoot, Ryze e WhatsApp, defina o que comprova sucesso em cada sistema. Em “Excluir só no Chatwoot”, a equipe vê a exclusão ao reabrir a conversa e o cliente continua vendo o original no WhatsApp. Se o defeito voltar, revise a hipótese e identifique a evidência que falta antes de aplicar outro ajuste.
