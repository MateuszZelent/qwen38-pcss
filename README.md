# Qwen3.8-27B na H100 w PCSS + Codex przez SSH

Ten katalog przygotowuje minimalny, prywatny tor:

```text
Codex CLI na PC                         PCSS compute node
localhost:8000  <==== SSH tunnel ====>  127.0.0.1:8000
                                           |
                                           +-- Apptainer/Singularity
                                               +-- vLLM OpenAI Responses API
                                               +-- Qwen/Qwen3.8-27B
```

Model nie powinien być wbudowywany do obrazu SIF. Obraz zawiera runtime
vLLM, a checkpoint jest przechowywany na współdzielonym filesystemie PCSS,
który jest widoczny na węźle obliczeniowym.

## Co jest już przygotowane

- `apptainer/qwen38-vllm.def` — definicja obrazu oparta na oficjalnym obrazie
  vLLM.
- `scripts/build-image.sh` — budowanie SIF w trybie `fakeroot`, `userns` albo
  uprzywilejowanym.
- `scripts/download-model.sh` — pobranie checkpointu przez
  `huggingface_hub` do scratchu.
- `scripts/serve-local.sh` — start vLLM z parserem tool calls Qwena i
  interfejsem Responses API.
- `slurm/qwen38-vllm.sbatch.example` — szablon joba Slurm.
- `scripts/tunnel-ssh.sh` — tunel z komputera do węzła obliczeniowego.
- `config/codex-config.toml.example` — fragment konfiguracji Codex CLI.

## Ważna uwaga o świeżo wydanym modelu

Qwen3.8-27B jest świeżym checkpointem. Aktualna dokumentacja vLLM pokazuje
obsługę Qwen3/Qwen3.5, ale lista modeli może aktualizować się z opóźnieniem.
Dlatego pierwszy build używa tagu `nightly`; po udanym uruchomieniu należy
zapisać dokładny tag lub digest obrazu i dopiero wtedy traktować go jako
wersję reprodukowalną. Jeśli PCSS nie pozwala pobierać obrazu `nightly`,
zmień `From:` w pliku `.def` na `vllm/vllm-openai:latest` i sprawdź preflight.

## 1. Uzupełnij konfigurację PCSS

```bash
cp qwen38-pcss/config/pcss.env.example qwen38-pcss/config/pcss.env
${EDITOR:-vi} qwen38-pcss/config/pcss.env
```

Wpisz przede wszystkim:

- absolutną ścieżkę do scratchu dostępnego na compute node,
- nazwę partycji i typ zasobu GPU w pliku Slurm,
- login/host PCSS,
- nazwę compute node po otrzymaniu alokacji.

Nie commituj `pcss.env`; plik jest przeznaczony na lokalne dane infrastruktury.

## 2. Zbuduj obraz

Na hoście, na którym dostępny jest Apptainer/Singularity:

```bash
cd qwen38-pcss
./scripts/build-image.sh
```

Jeśli PCSS wymaga trybu user namespace:

```bash
APPTAINER_BUILD_MODE=userns ./scripts/build-image.sh
```

Budowanie może wymagać kilku–kilkunastu GB tymczasowego miejsca. Ustaw
`APPTAINER_TMPDIR` na filesystem z odpowiednim limitem, jeśli `/tmp` jest
mały.

## 3. Pobierz model

Jeśli model jest gated albo PCSS wymaga uwierzytelnienia, ustaw token tylko
w środowisku sesji:

```bash
export HF_TOKEN='...'
./scripts/download-model.sh
```

Bez tokena skrypt próbuje pobrać publiczny checkpoint.

## 4. Uruchom job na H100

Skopiuj szablon i dopasuj dyrektywy `#SBATCH` do PCSS:

```bash
cp slurm/qwen38-vllm.sbatch.example slurm/qwen38-vllm.sbatch
${EDITOR:-vi} slurm/qwen38-vllm.sbatch
sbatch slurm/qwen38-vllm.sbatch
```

Na pierwszym uruchomieniu zacznij od `MAX_MODEL_LEN=32768`, jednej sekwencji
i BF16. Dopiero po przejściu healthchecku zwiększaj kontekst do 65536 lub
więcej. H100 powinien pozwolić na model w pełnej precyzji, ale dokładny limit
zależy od wariantu H100, dostępnej pamięci i konfiguracji KV cache.

Po otrzymaniu numeru joba sprawdź węzeł:

```bash
squeue -j JOB_ID -h -o '%N'
```

Do tunelu potrzebna będzie nazwa tego węzła.

## 5. Zestaw tunel z komputera

Na komputerze, z którego uruchamiasz Codex CLI, ustaw w `pcss.env`:

```bash
SSH_LOGIN=user@login.pcss.example
SSH_COMPUTE_HOST=compute-node-from-squeue
```

Domyślny tryb używa `ProxyJump` i utrzymuje vLLM na `127.0.0.1` compute node:

```bash
./scripts/tunnel-ssh.sh
```

Pozostaw ten proces uruchomiony. W drugim terminalu sprawdź API:

```bash
./scripts/healthcheck.sh
```

Jeśli polityka PCSS nie pozwala na SSH bezpośrednio do compute node, użyj
`SSH_TUNNEL_MODE=login-hop` zgodnie z komentarzem w skrypcie. Ten wariant
wymaga, żeby compute node był osiągalny z login node; nie wystawiaj portu
vLLM do publicznej sieci.

## 6. Podłącz Codex CLI

Skopiuj zawartość `config/codex-config.toml.example` do swojej istniejącej
konfiguracji `~/.codex/config.toml`, zachowując pozostałe ustawienia. Następnie:

```bash
export PCSS_VLLM_API_KEY=dummy
./scripts/codex-pcss.sh
```

Wartość `model` musi być identyczna z `MODEL_NAME` przekazanym do vLLM.
Tunel daje lokalny adres `http://127.0.0.1:8000/v1`; Codex nie musi znać
adresu PCSS.

To jest konfiguracja Codex CLI. Aplikacja desktopowa może mieć osobny cykl
konfiguracji i nie należy zakładać, że automatycznie przejmie lokalnego
provider-a z pliku CLI.

## Kryteria gotowości

1. `nvidia-smi` działa na compute node.
2. `apptainer exec --nv qwen38-vllm.sif python -c 'import torch; ...'` widzi H100.
3. `GET /health` oraz `GET /v1/models` odpowiadają przez tunel.
4. Test `POST /v1/responses` przechodzi z nazwą `qwen3.8-27b`.
5. Codex wykonuje przynajmniej jeden bezpieczny tool call, np. odczyt pliku,
   a nie tylko generuje tekst.

Pierwsze cztery punkty potwierdzają uruchomienie. Dopiero punkt piąty
potwierdza, że parser tool calls i Responses API są zgodne z Codexem.

## Źródła techniczne

- [vLLM + Codex](https://docs.vllm.ai/en/latest/serving/integrations/codex/)
- [vLLM OpenAI-compatible server](https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/)
- [Apptainer GPU support](https://apptainer.org/docs/user/main/gpu.html)
- [Apptainer definition files](https://apptainer.org/user-docs/master/definition_files.html)
- [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B)
