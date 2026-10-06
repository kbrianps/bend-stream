# bend-stream

[English](README.md) · [![test](https://github.com/kbrianps/bend-stream/actions/workflows/test.yml/badge.svg)](https://github.com/kbrianps/bend-stream/actions/workflows/test.yml)

Clientes RTSP e RTMP escritos em [Bend 2](https://github.com/bendlang/bend). Os protocolos são todos em Bend; um arquivo em C, `net.c`, dá aos sockets o que os do Base não têm: host por nome, TLS e leitura com prazo.

É uma biblioteca (uma sessão entrega quadros, veja abaixo) e um gravador feito com ela:

```sh
bend pull.bend -o pull
./pull rtsp://usuario:senha@camera.exemplo:554/stream saida.ts 10
./pull rtmp://192.168.0.20/live/cam saida.flv 10
```

`rtsps://` e `rtmps://` são os mesmos sob TLS (a `libssl` do OpenSSL é aberta em tempo de execução). O certificado é conferido contra o nome do host e o repositório do sistema, ou contra o arquivo PEM que `STREAM_CAFILE` indicar.

O último argumento é quantos segundos gravar (10 se omitido). O programa imprime o que fez, ou o erro:

```
ok: H264+PCMA, 125 frames, 142543 bytes
```

## O que faz

**RTSP** (RFC 2326)

- `DESCRIBE`, `SETUP`, `PLAY`, `GET_PARAMETER` como keep-alive na metade do timeout da sessão, `TEARDOWN`.
- Autenticação Basic e Digest (MD5, e SHA-256 da RFC 7616), com usuário e senha da URL ou das opções.
- Segue redirect (um 3xx com `Location`), até cinco seguidos.
- SDP: escolhe o stream de vídeo e a URL de controle.
- RTP pela própria conexão RTSP (TCP intercalado).
- H.264 (RFC 6184: unidades simples, STAP-A, FU-A) e H.265 (RFC 7798: unidades simples, pacotes de agregação, unidades de fragmentação).
- Entrega imagens inteiras (access units em Annex B) e os quadros de áudio, cada um com seu tempo: AAC (RFC 3640) com cabeçalho ADTS, ou amostras G.711 (PCMA e PCMU, o que a maioria das câmeras manda).
- O gravador escreve cru (`ffplay saida.h264` toca); em `.ts`, como MPEG-TS com o áudio AAC e o tempo de cada quadro; em `.flv`, com o tempo de cada quadro e o áudio que vier, inclusive G.711; ou só o áudio, em `.aac`, `.alaw` ou `.ulaw`.

**RTMP**

- O handshake simples, o chunk stream nos dois sentidos (os quatro tipos de cabeçalho, timestamp estendido, Set Chunk Size), AMF0.
- `connect`, `createStream`, `play`; responde pings e manda acknowledgements.
- Entrega as mensagens de áudio e vídeo e os metadados como tags; o gravador escreve como arquivo FLV, sejam quais forem os codecs, ou tira os quadros para um `.ts` ou um arquivo cru: H.264, H.265 (enhanced RTMP, que o cliente anuncia no `connect`), AAC e G.711.
- O login vai na query da URL (`rtmp://host/app?user=...&pass=...`), como esperam os servidores que usam um.

## A biblioteca

Uma sessão entrega quadros; o que fazer com eles é assunto do programa. Função em Bend não pode ser chamada duas vezes, então não há callback: o programa pede o próximo quadro, como no `av_read_frame`.

```python
import 0x549ec15ed24ab103abe18a252f491fa4/rtsp.bend as S
import 0x549ec15ed24ab103abe18a252f491fa4/opts.bend as E
import 0x549ec15ed24ab103abe18a252f491fa4/frame.bend as F

# open: conecta, faz login, prepara os streams, dá play
r : S.Opened() <- S.Rtsp.open(E.Opts.new("rtsp://usuario:senha@camera/stream"))
#   Done{s}   uma sessão
#   Fail{e}   um E.Err: o motivo, um código, um texto

# next: um quadro, e a sessão para continuar
r : S.Read() <- S.Rtsp.next(s)
#   Done{(s, F.Video{pts, key, data})}   uma imagem: suas unidades NAL em Annex B
#   Done{(s, F.Audio{pts, data})}        quadros AAC com ADTS, ou amostras G.711
#   Fail{e}                              a sessão acabou, a conexão foi fechada

S.Rtsp.close(s)
```

Essas linhas buscam o pacote no hub do Bend; os outros arquivos estão sob o mesmo hash (`rtmp.bend`, `rec.bend`, `flv.bend`, `conn.bend`...). Ou clone este repositório e importe `./rtsp.bend`. Um programa que usa a biblioteca é compilado nativo (`bend programa.bend -o programa`), porque os sockets estão em `net.c`.

[`examples/frames.bend`](examples/frames.bend) é esse laço, inteiro, imprimindo cada quadro; [`pull.bend`](pull.bend) é o gravador.

**Opções** (`opts.bend`): `E.Opts.new(url)`, e depois qualquer uma de `E.Opts.login(o, usuario, senha)` (no lugar dos da URL), `E.Opts.wait(o, ms)` (quanto o servidor pode ficar calado; 10 s), `E.Opts.audio(o, False{})` (só vídeo), `E.Opts.ca(o, "ca.pem")` (o certificado em que confiar sob TLS).

**Quadros** (`frame.bend`): `pts` vem em ticks de 90 kHz desde o primeiro quadro do stream; `key` diz que um decodificador pode começar ali. `S.Rtsp.about(s)` devolve a sessão com um `F.Info`: o codec (`"H264"` ou `"H265"`), os parameter sets que o servidor anunciou e o codec do áudio (`"AAC"`, `"PCMA"`, `"PCMU"` ou `""`).

**Erros** (`opts.bend`): um `E.Err{why, code, msg}`. O `why` é o que o programa usa para decidir:

| `why` | Significado | O que fazer |
|---|---|---|
| `NoRoute` | não conecta (nome, porta, rede) | tentar de novo depois |
| `Silent` | o servidor não mandou nada por `wait` ms | tentar de novo |
| `Hangup` | a conexão fechou ou quebrou | tentar de novo |
| `Ended` | o stream chegou ao fim (RTMP) | nada: não é falha |
| `NoLogin` | usuário e senha errados ou ausentes | pedir outros |
| `NoStream` | o servidor não tem esse stream | desistir |
| `Unsafe` | o TLS falhou (certificado, handshake) | desistir |
| `Refused` | o servidor recusou um pedido | desistir |
| `Garbled` | o que veio não é o protocolo | desistir |
| `BadUrl` | não é uma URL desse protocolo | desistir |

`E.Err.show(e)` põe um erro numa linha, e `E.Err.again(e)` diz se abrir de novo pode funcionar (os três primeiros).

**Reconexão**: `S.Rtsp.reopen(opts, until)` (e `M.Rtmp.reopen`) reabre uma sessão perdida: espera meio segundo, tenta, dobra a espera até 15 s a cada falha, e termina quando a sessão abre, quando um erro diz que nunca vai abrir (`E.Err.lasting(e)`: o login, o certificado ou a URL), ou quando o relógio chega em `until`. O gravador usa isso: um stream que cai continua no mesmo arquivo, com os tempos depois do último quadro gravado, e o resultado diz `reconnected 2 times`.

**Gravação** (`rec.bend`): `W.Rec.for(path, info)` cria um gravador na forma que o nome do arquivo pede (`.ts`, `.flv`, só o áudio, ou cru), e `W.Rec.put(rec, frame)` devolve os bytes a escrever e o gravador para continuar.

**RTMP** (`rtmp.bend`) são as mesmas três chamadas, `M.Rtmp.open`, `M.Rtmp.next`, `M.Rtmp.close`, e entrega tags (`K.Tag{typ, ts, data}`): escritos depois de `K.Flv.header()`, cada um como `K.Flv.of(tag)`, formam um arquivo FLV. `V.Flv.frames(state, tag)` (`flv.bend`) tira o quadro de dentro do tag, o mesmo `F.Frame` de uma sessão RTSP, então um stream RTMP também grava em `.ts`.

## Arquivos

| Arquivo | O que tem |
|---|---|
| `rtsp_core.bend` | Puro: URLs, pedidos, respostas e quadros intercalados, autenticação, SDP |
| `rtp.bend`, `depay.bend` | Puro: pacotes RTP, unidades H.264 e H.265, Annex B; quadros a partir dos pacotes |
| `frame.bend` | O que uma sessão entrega: `Frame` e `Info` |
| `rec.bend`, `ts.bend`, `audio.bend` | Puro: quadros para um arquivo (cru, MPEG-TS: PAT, PMT, PES, o relógio), AAC com ADTS |
| `flv.bend`, `flvw.bend` | Puro: quadros a partir dos tags do RTMP, e quadros para um arquivo FLV (H.264, H.265, AAC e G.711 como o FLV guarda) |
| `rtmp_core.bend` | Puro: handshake, chunks, comandos, o que cada mensagem significa, FLV |
| `amf.bend` | Puro: AMF0 |
| `bytes.bend`, `text.bend`, `b64.bend`, `md5.bend`, `sha256.bend` | Auxiliares puros |
| `rtsp.bend`, `rtmp.bend` | O IO: as duas sessões |
| `opts.bend` | Puro: opções, e erros com motivo |
| `conn.bend` | Abertura, leituras e escritas de uma conexão |
| `net.bend`, `net.c`, `net.js` | Os sockets: nomes, TLS, prazos (só nativo; o lado JS recusa) |
| `pull.bend`, `examples/` | O gravador, e programas menores que usam a biblioteca |
| `LAWS.bend`, `PROOF.bend` | As leis e suas provas |

## Leis

`bend PROOF.bend` imprime `ALL PROOFS CHECK` só enquanto toda lei de [`LAWS.bend`](LAWS.bend) vale. Algumas valem para toda entrada:

- nenhum pedaço de um pedido RTSP carrega CR ou LF, para toda string, então uma URL ou um valor de cabeçalho não consegue iniciar outro cabeçalho ou outro pedido (por indução);
- a junção de listas de bytes com que todo buffer é montado é a junção comum de listas, para quaisquer duas listas (por indução);
- um TS que não anunciou áudio nunca carrega pacote de áudio, um arquivo de áudio não leva nada de uma imagem, e um arquivo de vídeo cru não leva áudio, seja qual for o estado e o quadro;
- o que não é pacote RTP, ou um tag que não é áudio nem vídeo, não gera quadro e não muda nada;
- nenhum motivo de falha é ao mesmo tempo dos que duram e dos que valem outra tentativa.

As outras são os exemplos das próprias normas, conferidos pelo compilador:

- a resposta do Digest é o exemplo da RFC 2617 3.5, e os da RFC 7616 3.9.1 com SHA-256 e MD5; o SHA-256 dá os vetores da FIPS 180-4; o Basic é o exemplo da RFC 7617;
- uma unidade H.264 partida em fragmentos FU-A sai inteira, e um fragmento cujo início se perdeu não gera nada;
- os números do AMF0 são os doubles IEEE 754 certos, e um campo de um objeto de status é achado depois de ida e volta;
- um tag FLV tem os bytes que o formato manda, e os quadros saem dos tags como devem: H.264, H.265 como o enhanced RTMP carrega, G.711;
- o PAT é byte a byte o que todo muxer escreve, com o CRC, e um pacote PES de qualquer tamanho sai em pacotes inteiros de 188 bytes.

`bend PROOF.bend --verdict` reconfere as provas com o núcleo pequeno do Bend, que é provado em Lean. Uma por vez, 29 das 30 leis passam. O exemplo do Digest com SHA-256 não passa: o núcleo calcula passo a passo com um orçamento fixo e fica sem combustível num hash de vários blocos, o que o `--verdict` mostra como "mismatch" (Bend 2.0.35; o mesmo limite de [bendlang/bend#1193](https://github.com/bendlang/bend/issues/1193) e [#1322](https://github.com/bendlang/bend/issues/1322)). O compilador confere essa lei, e a mesma troca com MD5 passa no núcleo.

## Testes

```sh
./test.sh
```

Prova as leis, compila o binário, sobe um [mediamtx](https://github.com/bluenviron/mediamtx) local alimentado pelo `ffmpeg`, grava dele pelos dois protocolos e confere cada arquivo com o `ffprobe`. Cobre também TLS, com um certificado criado na hora. Precisa de `mediamtx`, `ffmpeg`, `ffprobe`, `openssl` e `python3` (um servidor que só redireciona). `AUTH=basic ./test.sh` roda com Basic no lugar de Digest, e `OTHERS=1 ./test.sh` acrescenta, em Docker, RTMP a partir do SRS e do nginx-rtmp, e H.265 e G.711 por RTMP a partir de um mediamtx recente.

Além do script, o cliente RTSP rodou contra gravadores reais, em MPEG-TS: um DVR Intelbras MHDX e um NVR Hikvision DS-7632NXI-K2 em H.264, e uma câmera em H.265 com áudio G.711 (PCMU), que também gravou inteira (imagem e som) em FLV.

## Limites

- RTSP: só RTP pela conexão RTSP (sem UDP). O G.711 não cabe num TS: uma câmera com ele grava inteira em `.flv`.
- Áudio e vídeo são alinhados pelo primeiro pacote de cada um, não pelos sender reports do RTCP.
- RTMP: só reprodução, sem publicar. Login ausente aparece como "the server closed the connection".
- O TS usa o timestamp do RTP como tempo de apresentação e de decodificação, o que é errado para stream com B-frames (câmeras raramente geram).
- O FLV de um stream RTMP mantém os timestamps do servidor, então pode não começar em zero. Do enhanced RTMP só o H.265 é lido (sem AV1, VP9 ou multitrack).
- Uma sessão perdida não se conserta sozinha: o `next` diz por que falhou, e o programa chama o `reopen` (o gravador faz isso).
- Só nativo: `bend pull.bend` sozinho roda o lado JS, que não tem esses sockets.
- Bytes são listas ligadas em Bend: conte com uns 280 MB de memória para um stream 640x360.

Testado com o Bend 2.0.35.

## Licença

MIT
