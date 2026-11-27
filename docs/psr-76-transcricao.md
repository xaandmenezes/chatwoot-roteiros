# Transcrição dos áudios do WhatsApp no Chatwoot

A PSR-76 acrescenta a transcrição privada aos novos áudios recebidos e enviados na caixa Ryze configurada, incluindo notas de voz do microfone e arquivos MP3. O agente pode ouvir o áudio durante o processamento ou se o reconhecimento falhar. A habilitação inicial em produção é exclusiva da conversa de teste #71.

## Processamento e acesso

O Chatwoot cria um registro por anexo e agenda sua transcrição após o commit. O Sidekiq lê o arquivo do Active Storage e o envia com um nome genérico ao whisper.cpp, pela rede interna do Compose. O serviço usa FFmpeg para decodificar a mídia e o modelo multilíngue small quantizado em Q5_1, com idioma português. Cada processo Sidekiq habilitado tem um consumidor e uma conexão adicional no pool de banco para essa fila. O contêiner de inferência tem limite de duas CPUs, 2 GiB de memória e área temporária em RAM. O serviço fica sem porta pública, volume de saída ou logs de mídia.

O texto permanece em uma tabela privada com vínculo ao anexo. O painel consulta grupos de até 100 IDs mediante sessão autenticada e permissão de acesso à conversa. A transcrição não cria mensagem, evento de entrega ou nota privada. A exclusão do anexo remove sua transcrição. Arquivos maiores que 25 MB e formatos incompatíveis recebem estado de falha. A conexão ao transcritor expira após 180 segundos por tentativa. Falhas transitórias permitem até três tentativas. Não há importação retroativa.

## Preparar o modelo para o Dokploy

Execute na VPS durante a preparação autorizada da release. O modelo precisa estar legível para o UID 65534. O download usa uma revisão fixada e a verificação antecede a instalação.

```sh
(
set -eu
model_dir=/var/lib/psr/whisper-models
install -d -m 0755 "$model_dir"
model_tmp=$(mktemp)
trap 'rm -f "$model_tmp"' EXIT
curl --fail --location --retry 3 -o "$model_tmp" \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin
echo "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb  $model_tmp" | sha256sum --check -
install -m 0444 "$model_tmp" "$model_dir/ggml-small-q5_1.bin"
)
```

O [Compose do Dokploy](../docker-compose.dokploy.yml) fixa a imagem oficial do whisper.cpp v1.9.6 para linux/amd64 pelo digest. Ative o perfil Compose `transcription` com `COMPOSE_PROFILES=transcription` no ambiente do Compose ou com `--profile transcription`. Preserve os overrides da aplicação existentes no Dokploy. O Compose monta o [conversor de áudio](../docker/whisper/ffmpeg) que limpa arquivos temporários se a decodificação falhar. Com Compose em modo Raw, instale esse arquivo da mesma revisão com permissão 0755 e aponte `RYZE_AUDIO_TRANSCRIPTION_FFMPEG_WRAPPER` para o caminho absoluto na VPS. O diretório do modelo pode ser indicado com `RYZE_AUDIO_TRANSCRIPTION_MODEL_DIR`.

## Piloto e reversão

1. Com a release autorizada, mantenha o `RYZE_INBOX_ID` da caixa Ryze e configure **juntos** `RYZE_AUDIO_TRANSCRIPTION_CONVERSATION_ID=71` e `RYZE_AUDIO_TRANSCRIPTION_ENABLED=true` para Rails e Sidekiq. O número do piloto é o que aparece no painel. O escopo vazio mantém o recurso inativo. Após aprovação da expansão, o valor explícito `all` habilita a caixa inteira.
2. Aplique a migração pelo serviço `prepare`. Confira a revisão de Rails e Sidekiq, o `/health` do Chatwoot e o healthcheck interno de `ryze-transcriber`. Observe a fila `ryze_audio_transcription` no Sidekiq.
3. Após autorização específica do titular da #71 para a rodada, receba uma nota de voz e envie, pelo painel, um áudio de microfone e um MP3. Use uma frase conhecida com nomes de destinos. Verifique a entrega no WhatsApp, o player e a transcrição de cada anexo, inclusive após reabrir a conversa. Confirme no telefone que apenas os áudios chegaram.
4. Registre revisão, responsável, IDs das três mensagens, fidelidade aos nomes e resultado da entrega na [PSR-76](https://linear.app/porto-seguro-roteiros/issue/PSR-76). A expansão do piloto depende dessa avaliação.

Para desativar, defina `RYZE_AUDIO_TRANSCRIPTION_ENABLED=false` em Rails e Sidekiq e recrie os serviços. O painel oculta os textos e o processamento para após a troca dos processos. O perfil e o serviço de inferência podem então ser desligados. Os áudios e os registros já concluídos são preservados.

## Referência de validação local

Uma fala sintética de aproximadamente seis segundos com “Trancoso”, “Caraíva” e “Porto Seguro” foi reconhecida nos três formatos OGG/Opus, WebM/Opus e MP3. O teste pelo job Rails gravou uma única transcrição por anexo, inclusive ao repetir o job. Um arquivo inválido seguido dos três áudios válidos também confirmou a limpeza dos temporários e a continuidade do serviço. Cada chamada de inferência válida levou entre 12 e 14 segundos no ambiente local ARM com duas CPUs alocadas. O piloto mede a qualidade com a captação do WhatsApp e o tempo na VPS amd64.

[Servidor e opções do whisper.cpp](https://github.com/ggml-org/whisper.cpp/blob/v1.9.6/examples/server/README.md) · [Modelo e consumo de memória](https://github.com/ggml-org/whisper.cpp#memory-usage)
