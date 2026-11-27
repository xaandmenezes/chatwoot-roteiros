# Orquestração de IA da PSR

Projeto no [Linear](https://linear.app/porto-seguro-roteiros/project/implementacao-chatwoot-roteiros-fe7deb79accd), UUID `0215754d-519a-40c2-be04-cfca97743aa7`.

## Orquestração e modelos

O chat principal do T3 usa **Gemini 4 Hydrogen** (`google/gemini-4-hydrogen`): planeja, coordena, revisa evidências e sintetiza; delega buscas amplas, auditorias, implementações e validações.

A família padrão dos delegados é **Codex** (`providerInstanceId: "codex"`), com `serviceTier: "priority"` (Fast) explícito nos papéis operacionais (Explorer, Fixer, Validator, Designer, Observer, Hunter e Paladin); o **Oracle** usa `reasoningEffort: "high"` com `serviceTier` padrão (ou `priority` se solicitado na sessão). Para mudar de família na sessão, diga “Use a família X nos papéis nesta sessão”; para voltar, diga “Use a família do projeto”.

Chame `orchestrator_capabilities` uma vez antes da primeira delegação. Em cada delegação, passe explicitamente `providerInstanceId`, `model`, `reasoningEffort` e `serviceTier`, conforme o catálogo disponível. Se uma opção não estiver disponível, informe a limitação.

| Papel e responsabilidade | Modelo e configuração | Skills |
| --- | --- | --- |
| Orchestrator — coordenar, definir aceite, revisar evidências e entregar | `google/gemini-4-hydrogen` no chat | `agy-fast`, `linear-issues`, `git-worktrees`, `rails-8-modern`, `tdd-and-testing`, `vue-best-practices`, `verification-planning`, `step-back` |
| Explorer — leitura, busca e inventário | `gpt-6-luna`, low, priority | `agy-fast`, `systematic-debugging` |
| Fixer — implementação, docs, configs e scripts | `gpt-6.1-terra`, medium, priority | `agy-fast`, `git-worktrees`, `tdd-and-testing`, `rails-8-modern`, `vue-best-practices` |
| Validator — consistência, testes, lint e checks | `gpt-6.1-terra`, high, priority ou `gpt-6.2-sol`, medium, priority | `agy-fast`, `tdd-and-testing`, `webapp-testing`, `vue-best-practices`, `verification-planning` |
| Designer — aparência e interação | `gpt-6-luna`, medium, priority | `better-interface`, `vue-best-practices` |
| Observer — experiência visual e browser | `gpt-6-luna`, medium, priority | `webapp-testing`, `yab-browser` quando indicado |
| Hunter — falhas silenciosas e reentregas | `gpt-6.2-sol`, medium, priority | `agy-fast`, `systematic-debugging`, `step-back` |
| Paladin — segurança e permissões | `gpt-6.2-sol`, high, priority | `agy-fast`, `code-review-and-security`, `security-audit` |
| Oracle — conflito arquitetural real ou diagnóstico complexo; registre o motivo | `gpt-6.2-astra`, high, default | `agy-fast`, `systematic-debugging`, `code-review-and-security`, `step-back` |

Na tabela, low, medium e high são valores de `reasoningEffort`; priority e default são valores de `serviceTier`.

## Busca e verificação com agy-fast

O orquestrador e os delegados usam `agy-fast` via shell:

- `agy-fast search --text "..."`, `--regex` ou `--glob` para buscas em lote.
- `agy-fast outline <arquivo>` antes de ler arquivos com mais de 300 linhas.
- `agy-fast slice "arquivo:inicio-fim"` para leituras direcionadas.
- `agy-fast check --compact "cmd1" "cmd2"` para checks pass/fail em paralelo.

No shell do Codex, `--compact` trunca saídas multilinha à última linha: use-o apenas para checks pass/fail, como testes e lint, nunca para listagens completas de `git branch`, `git worktree list`, `git diff` ou `ls`. Evite `~` em subshells de `agy-fast check`; use `$HOME` ou caminho absoluto.

## Skills

O acervo da equipe fica em `$HOME/.config/skillshare/skills/`, ligado ao diretório de descoberta `$HOME/.agents/skills/`. Confira `agy-fast`, `linear-issues`, `git-worktrees`, `rails-8-modern` e `tdd-and-testing`, além das skills pertinentes ao papel. Leia o `SKILL.md` antes de aplicar cada skill. `verification-planning` e `step-back` são práticas que não precisam de instalação.

Para Vue 3, use `vue-best-practices` de [vuejs-ai/skills](https://github.com/vuejs-ai/skills/tree/198f0cd8f7f9c0a3d9b566ccc16de6677519ee78/skills/vue-best-practices). Instale a revisão fixada com:

```sh
python3 "$HOME/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py" \
  --repo vuejs-ai/skills --path skills/vue-best-practices \
  --ref 198f0cd8f7f9c0a3d9b566ccc16de6677519ee78 --method git --dest "$HOME/.agents/skills"
```

## Branches, CI e equipe

Cada issue tem responsável e branch/worktree própria a partir de `origin/develop` atualizado. Abra PR para `develop`, vinculado à issue, com revisão de outra pessoa e validação local. A release segue por PR `develop` → `prod`, com issues e responsável, e autorização de deploy antes do merge. Push direto nas duas branches é proibido. Hotfix parte de `prod`, passa por PR para `prod` com revisão, verificações e autorização, e depois volta por PR para `develop`. Após deploy, confira versão ativa, `/health` e Sidekiq. O fluxo de build e deploy está em [Build e deploy da imagem PSR](psr-image-ci.md).

Confira responsável e estado no Linear antes de assumir uma issue. Na passagem de trabalho, registre branch ou PR, resultado, pendências e próxima ação. Testes reais de envio, edição, reação ou exclusão exigem conversa e ações autorizadas para a rodada; a conversa `#71` exige autorização específica de Vinicius A. Freire para aquela rodada.

## Prompt de inicialização — copie para uma nova conversa

> Inicie [issue ou objetivo] como orquestrador Gemini 4 Hydrogen no T3. Use delegados Codex (papéis operacionais com Fast/`priority`; Oracle com `default`) e `agy-fast` via shell. Confira o checkout, `AGENTS.md`, `docs/orquestracao-ia-psr.md` e `docs/psr-image-ci.md`. Consulte o projeto Linear pelo UUID `0215754d-519a-40c2-be04-cfca97743aa7`, a issue, responsável e aceite. Confira as skills pertinentes em `~/.agents/skills/` e o catálogo antes de delegar. Use branch/worktree da issue baseada em `origin/develop`, PR com validação e revisão, e autorização antes do merge em `prod`. Restrinja testes reais às ações e conversa autorizadas; a `#71` exige autorização específica de Vinicius A. Freire para a rodada. Registre resultados e passagem no Linear.
