# Orquestração de IA da PSR

Projeto: https://linear.app/porto-seguro-roteiros/project/implementacao-chatwoot-roteiros-fe7deb79accd

### Família dos modelos

O OMO Slim inspira a divisão dos papéis. Cada pessoa pode trabalhar no executor da equipe sem instalar o OMO Slim. O usuário escolhe o modelo do chat principal no T3. A preferência atual é Astra High, Fast desligado. A família abaixo governa apenas os papéis delegados.

Leia o valor vigente da linha **Família padrão dos papéis** no projeto do Linear.

Para mudar nesta sessão, diga **“Use a família Claude nos papéis nesta sessão”** (ou Gemini, Codex ou outra disponível). Para mudar o padrão do projeto, edite apenas a linha **Família padrão dos papéis** na descrição do Linear. A instrução explícita da sessão prevalece sobre o padrão. Uma troca de família conserva as responsabilidades, skills, esforço equivalente e Fast nas delegações. Para voltar ao padrão, diga **“Use a família do projeto”**.

Ao delegar, consulte o catálogo real do executor e escolha, na família ativa, um modelo com a capacidade, as ferramentas e a prioridade necessárias. Passe modelo, esforço e Fast explicitamente. Os modelos na tabela são referências para Codex. Se faltar modelo, ferramenta ou Fast, declare a limitação e as opções disponíveis antes de usar outra família ou prioridade. Uma instrução no chat orienta as próximas delegações; o seletor do T3 controla o modelo da conversa principal.

### Papéis e instalação de skills

Acione somente os papéis e as skills úteis à tarefa. A identifica skills do acervo da equipe. B identifica práticas da equipe. C identifica a skill pública de Vue, com instalação reproduzível abaixo.

| Papel e responsabilidade | Referência Codex | Skills e instalação |
| --- | --- | --- |
| Orchestrator — coordenar, definir aceite e entregar | Astra High no chat | A: `linear-issues`, `git-worktrees`, `rails-8-modern`, `tdd-and-testing`; C: `vue-best-practices`; B: `verification-planning`, `step-back` |
| Explorer — localizar código, rotas e configuração | Luna 6 · baixo | Busca comum com Git e `rg`; A: `systematic-debugging` para rastrear comportamento |
| Fixer — implementar, preparar PR e executar deploy conhecido | Terra 6.1 · médio | A: `git-worktrees`, `tdd-and-testing`, `rails-8-modern` para mudanças Rails; C: `vue-best-practices` para componentes do painel |
| Designer — avaliar aparência e interação | Luna 6 · médio | A: `better-interface`; C: `vue-best-practices` para decisões de componentes |
| Observer — observar e registrar a experiência visual | Luna 6 · médio | A: `webapp-testing` em ambiente local; `yab-browser` quando o usuário indicar o Yab |
| Validator — verificar comportamento, imagem e serviços | Terra 6.1 · alto | A: `tdd-and-testing`, `webapp-testing`; C: `vue-best-practices` quando validar o painel; B: `verification-planning` |
| Hunter — diagnosticar falhas silenciosas e reentregas | Sol 6.2 · médio | A: `systematic-debugging`; B: `step-back` quando o defeito voltar |
| Paladin — revisar segurança e permissões | Sol 6.1 · alto | A: `code-review-and-security`, `security-audit` |
| Oracle — resolver dúvida de arquitetura, recuperação ou diagnóstico complexo | Astra · alto | A: `systematic-debugging`, `code-review-and-security`; B: `step-back`. Registre a decisão que motivou a chamada. |
| Proctor — opção futura para avaliar lacunas de cobertura | A definir se ativado | A: `tdd-and-testing`; B: `verification-planning` |

**A · Acervo da equipe.** No Mac da PSR, a origem é `~/.config/skillshare/skills/`. Em outro computador, copie da distribuição da equipe as pastas completas das skills necessárias para o diretório de descoberta do executor. No Codex, use `~/.agents/skills/`. O exemplo instala ou verifica a base do orquestrador e preserva instalações existentes. Ajuste a origem se o acervo estiver em outro local.

```sh
(
  set -eu
  origem="${PSR_SKILLS_DIR:-$HOME/.config/skillshare/skills}"
  destino="$HOME/.agents/skills"
  mkdir -p "$destino"
  for nome in linear-issues git-worktrees rails-8-modern tdd-and-testing; do
    if ! test -r "$destino/$nome/SKILL.md"; then
      test -r "$origem/$nome/SKILL.md" || { echo "Ausente no acervo: $nome" >&2; exit 1; }
      test ! -e "$destino/$nome" && test ! -L "$destino/$nome" || exit 1
      ln -s "$origem/$nome" "$destino/$nome"
    fi
    test -r "$destino/$nome/SKILL.md"
  done
)
```

**B · Práticas da equipe.** `verification-planning` significa combinar antecipadamente como verificar o resultado; `step-back` significa reavaliar a hipótese quando uma correção falha. Ambas podem ser aplicadas diretamente, sem instalar software.

**C · Vue 3.** Use `vue-best-practices` para Composition API, `<script setup>`, reatividade e contratos de props e eventos. Preserve a linguagem e a store adotadas no módulo. A origem é [vuejs-ai/skills, versão 19.1.0](https://github.com/vuejs-ai/skills/tree/198f0cd8f7f9c0a3d9b566ccc16de6677519ee78/skills/vue-best-practices). Para instalar só essa skill no Codex:

```sh
python3 "$HOME/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py" \
  --repo vuejs-ai/skills --path skills/vue-best-practices \
  --ref 198f0cd8f7f9c0a3d9b566ccc16de6677519ee78 --method git --dest "$HOME/.agents/skills"
```

Em outro executor, copie o diretório `skills/vue-best-practices` dessa mesma revisão, incluindo `references/`, para o local de skills que ele reconhece.

Após instalar uma skill, confira o `SKILL.md` e a descoberta pelo executor em uma nova sessão. Leia a skill antes de aplicá-la. Em outros provedores, use o diretório de descoberta documentado pelo executor. O acesso ao navegador, às credenciais e ao Linear é verificado separadamente.

### Trabalho em equipe

- **Início.** Confira no Linear o responsável, o estado e os PRs da issue. Ao assumir uma issue disponível, atribua-a à pessoa responsável e mova-a para “Em andamento”. Se já houver alguém trabalhando, combine a divisão e registre o escopo de cada pessoa.
- **Passagem de trabalho.** Deixe na issue a branch ou o PR, o que foi feito, o que está pendente e a próxima ação. Quem assumir consegue continuar em outro chat ou computador.
- **Testes de WhatsApp.** A conversa #71 é pessoal de Vinicius A. Freire. Somente Vinicius pode autorizar seu uso em uma rodada específica. Para testes da equipe, use uma conversa controlada com autorização, destino, ações permitidas e responsável registrados na issue. Uma autorização antiga vale apenas para a rodada em que foi dada.

### Prompt de inicialização — copie para uma nova conversa

> **Inicie a tarefa [PSR-… ou objetivo] como orquestrador do projeto Implementação Chatwoot Roteiros.**
>
> 1. **Identifique o checkout.** Confira a raiz, o remoto, a branch, o worktree e o estado do Git. Verifique `git ls-files --error-unmatch -- AGENTS.md`. Leia o AGENTS.md completo, o guia de orquestração e as instruções do diretório da tarefa. Se faltar o arquivo ou o rastreamento, compare com develop e regularize por PR vinculado à issue, preservando as alterações locais.
> 2. **Abra o projeto no Linear.** O T3 Code já tem acesso pelo MCP. Leia o projeto pelo UUID `0215754d-519a-40c2-be04-cfca97743aa7`; confira o nome, a equipe PSR e suas Regras para IA. Leia a issue, o aceite, os comentários recentes, o responsável e o PR existente. Se o executor estiver sem MCP, use a API GraphQL em `https://api.linear.app/graphql` com credencial já autorizada e verifique o campo `errors`. Se ambas as vias falharem, indique a limitação e prossiga com trabalho local independente.
> 3. **Prepare suas skills.** Confira agora se `linear-issues`, `git-worktrees`, `rails-8-modern`, `tdd-and-testing` e `vue-best-practices` estão acessíveis. Para cada ausente, use os procedimentos A ou C deste guia no ambiente da pessoa e confira o SKILL.md e os arquivos auxiliares. Se a origem do acervo estiver indisponível, identifique exatamente a skill faltante. Antes de delegar, confira também as skills do papel na tabela. Abra as instruções pertinentes à tarefa. As práticas B são aplicáveis diretamente.
> 4. **Conduza a tarefa de ponta a ponta.** Em Rails, confira rotas, serviços, jobs, persistência e permissões que sustentam o comportamento. Em Vue, confira componentes, reatividade, eventos, estado e atualização da conversa aberta. Em uma mudança que atravesse as duas camadas, explicite o contrato e escolha testes que exercitem o resultado visível. Use as versões e padrões do checkout.
> 5. **Coordene com a equipe.** Respeite quem já assumiu a issue. Escolha a família indicada para a sessão ou, por padrão, a do Linear. O chat principal prefere Astra High sem Fast; nas delegações indique papel, modelo disponível, esforço, Fast e entrega esperada. Trabalhe com PR e build externo conforme as regras do projeto. Para qualquer teste real, confirme o destino e as ações autorizadas para esta rodada. A #71 é pessoal de Vinicius e depende de autorização específica dele.
> 6. **Comece o trabalho.** Informe de forma breve a issue, a branch, o acesso ao Linear, as skills disponíveis ou faltantes e a primeira ação. Ao passar a tarefa adiante, atualize a issue com o PR, o resultado e o próximo passo.
