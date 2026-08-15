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
- `scripts/build-image.sh` — budowanie SIF w trybie `fakeroot`, `userns`,
  uprzywilejowanym albo przez wrapper administratorów PCSS.
- `scripts/download-model.sh` — pobranie checkpointu przez
  `huggingface_hub` do scratchu.
- `scripts/serve-local.sh` — start vLLM z parserem tool calls Qwena i
  interfejsem Responses API.
- `slurm/qwen38-vllm.sbatch` — gotowy job Slurm na jedną kartę H100.
- `scripts/tunnel-ssh.sh` — opcjonalny helper tunelu; tunel można też wykonać
  ręcznie.
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

W repozytorium jest już konfiguracja dla tego checkoutu: model, SIF, cache i
logi trafiają do `/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss`.
Nie dodajemy do niej loginu ani parametrów tunelu SSH.

Nie commituj `pcss.env`; plik jest przeznaczony na lokalne dane infrastruktury.

## 2. Zbuduj obraz

Na hoście, na którym dostępny jest Apptainer/Singularity:

```bash
cd qwen38-pcss
bash scripts/build-image.sh
```

Skrypt wykrywa `apptainer` albo `singularity` automatycznie. Ręczny odpowiednik
wygląda tak:

```bash
singularity build --fakeroot qwen38-vllm.sif apptainer/qwen38-vllm.def
```

Na PCSS konto użytkownika nie ma mapowania `fakeroot` (`/etc/subuid` i
`/etc/subgid`). Administratorzy udostępniają zamiast tego polecenie
`sudo singularity-build`, które ma tę samą składnię co `singularity build`.
Budowanie obrazu wykonaj więc z trybem wrappera:

```bash
APPTAINER_BUILD_MODE=admin-wrapper bash scripts/build-image.sh
```

Ręczny odpowiednik:

```bash
sudo singularity-build qwen38-vllm.sif apptainer/qwen38-vllm.def
```

Jeżeli wrapper wymaga hasła, wpisz je w terminalu. Po zakończeniu sprawdź,
czy obraz istnieje i ma właściwego właściciela:

```bash
ls -lh qwen38-vllm.sif
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

Job jest gotowy do zlecenia:

```bash
sbatch slurm/qwen38-vllm.sbatch
```

Domyślnie rezerwuje partycję `tesla`, `gpu:h100:1`, 8 CPU i 96 GB RAM.
Jeśli Twoja alokacja wymaga partycji `proxima`, zmień tylko
`#SBATCH --partition=tesla`.

Na pierwszym uruchomieniu zacznij od `MAX_MODEL_LEN=32768`, jednej sekwencji
i BF16. Dopiero po przejściu healthchecku zwiększaj kontekst do 65536 lub
więcej. H100 powinien pozwolić na model w pełnej precyzji, ale dokładny limit
zależy od wariantu H100, dostępnej pamięci i konfiguracji KV cache.

Po otrzymaniu numeru joba sprawdź węzeł:

```bash
squeue -j JOB_ID -h -o '%N'
```

Do ręcznego tunelu potrzebna będzie nazwa tego węzła.

## 5. Zestaw tunel z komputera

Na komputerze wykonaj ręcznie tunel do przydzielonego compute node. Przykład
z `ProxyJump` przez login PCSS:

```bash
ssh -N -T \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -J kkingstoun@eagle.man.poznan.pl \
  -L 8000:127.0.0.1:8000 \
  kkingstoun@NAZWA_COMPUTE_NODE
```

Pozostaw ten proces uruchomiony. W drugim terminalu sprawdź API:

```bash
./scripts/healthcheck.sh
```

Serwer pozostaje na `127.0.0.1` compute node i nie jest wystawiany publicznie.

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
2. `apptainer exec --nv qwen38-vllm.sif python -c 'import torch; ...'` (albo
   `singularity exec --nv`) widzi H100.
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
