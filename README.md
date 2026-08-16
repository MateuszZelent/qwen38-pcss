# Qwen3.8-27B na H100 w PCSS + Codex przez SSH

Ten katalog przygotowuje minimalny, prywatny tor:

```text
Codex Desktop/CLI                       PCSS compute node
localhost:18000 <==== SSH tunnel ====>  127.0.0.1:8000
       |                                   |
       +-- router localhost:8765            +-- Apptainer/Singularity
           +-- GPT -> ChatGPT                   +-- vLLM OpenAI API
           +-- Qwen -> vLLM                     +-- Qwen/Qwen3.8-27B
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

Profil full-power rezerwuje partycję `tesla`, `gpu:h100:4`, 32 CPU i 256 GB
RAM.
Jeśli Twoja alokacja wymaga partycji `proxima`, zmień tylko
`#SBATCH --partition=tesla`.

Checkpoint deklaruje natywny kontekst 262144 tokenów i wspiera rozszerzenie do
1010000. Profil full-power używa czterech H100 w TP=4, wag BF16, KV cache BF16,
`MAX_NUM_SEQS=1`, prefix caching, chunked prefill oraz wbudowanego MTP z trzema
tokenami draftu. Rozszerzenie jest przekazywane przez zagnieżdżone
`HF_OVERRIDES` zgodnie z receptą Qwen3.8 vLLM. Jest to profil maksymalnej jakości
dla jednego interaktywnego użytkownika; nie używa kwantyzacji FP8/NVFP4.
Draft MTP jest jawnie ograniczony do natywnych 262144 tokenów, więc powyżej
tego progu vLLM pomija spekulację i nadal obsługuje pełny target 1M. Na PCSS
wyłączony jest własny custom all-reduce vLLM na rzecz NCCL, ponieważ węzły nie
udostępniają kompletnej topologii P2P wewnątrz alokacji.

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
  -o GSSAPIAuthentication=no \
  -o PreferredAuthentications=publickey \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -J kkingstoun@eagle.man.poznan.pl \
  -L 127.0.0.1:18000:127.0.0.1:8000 \
  kkingstoun@NAZWA_COMPUTE_NODE
```

Pozostaw ten proces uruchomiony. W drugim terminalu sprawdź API:

```bash
./scripts/healthcheck.sh
```

Serwer pozostaje na `127.0.0.1` compute node i nie jest wystawiany publicznie.

## 6. Podłącz jednocześnie GPT i Qwen do Codex

Nie ustawiaj `PCSS_VLLM_API_KEY` i nie przełączaj całego Codex na provider
`pcss-vllm`. Wspólna lista modeli wymaga lokalnego routera. Router nasłuchuje
wyłącznie na `127.0.0.1:8765`: żądania GPT przekazuje do ChatGPT z użyciem
istniejącego logowania Codex, a `qwen3.8-27b` do tunelu vLLM na porcie 18000.

Pozostaw aktywny tunel SSH i sprawdź:

```powershell
curl.exe http://127.0.0.1:18000/v1/models
```

Zamknij Codex Desktop i uruchom w PowerShell z katalogu repo:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\setup-codex-router.ps1
```

Instalator zachowuje dotychczasową konfigurację i zadania, generuje wspólny
katalog GPT + Qwen, uruchamia router i tworzy odwracalną zarządzaną kopię
Desktop z widocznym modelem niestandardowym oraz pełną historią providerów.

Jeżeli Codex pochodzi z Microsoft Store, uruchamiaj utworzony launcher
`%USERPROFILE%\.qwen38-codex\desktop-patch\launchers\Codex-Qwen-and-GPT.cmd`.
Oryginalny pakiet Store pozostaje niezmieniony.

```powershell
# diagnostyka
.\scripts\setup-codex-router.ps1 -Action Status

# pełne wycofanie
.\scripts\setup-codex-router.ps1 -Action Restore
```

Dla samego Codex CLI w WSL/Linux:

```bash
./scripts/setup-codex-router.sh install
# cofnięcie: ./scripts/setup-codex-router.sh restore
```

Konfiguracja Qwen znajduje się w
`config/codex-router-models.json.example`. Wartość `api_key` jest wyłącznie
lokalnym znacznikiem wymaganym przez router; vLLM nie wymaga sekretu.

## Kryteria gotowości

1. `nvidia-smi` działa na compute node.
2. `apptainer exec --nv qwen38-vllm.sif python3 -c 'import torch; ...'` (albo
   `singularity exec --nv`) widzi H100.
3. `GET /health` oraz `GET /v1/models` odpowiadają przez tunel.
4. Test `POST /v1/responses` przechodzi z nazwą `qwen3.8-27b`.
5. Codex wykonuje przynajmniej jeden bezpieczny tool call, np. odczyt pliku,
   a nie tylko generuje tekst.
6. Lista Desktop zawiera bieżące modele GPT oraz `Qwen3.8-27B (PCSS H100)`,
   a wcześniejsze zadania pozostają widoczne.

## Eksperyment: DeepSeek-V4-Pro na wielu węzłach PCSS

DeepSeek-V4-Pro-0813 ma checkpoint około 893 GB i nie mieści się na jednym
węźle 4xH100. Osobny profil `slurm/deepseek-v4-pro-multinode.sbatch` rezerwuje
domyślnie cztery węzły (16 H100) i uruchamia DP=16 z Expert Parallel. Pierwszy
węzeł wystawia API wyłącznie na loopback, pozostałe działają headless.

```bash
cp config/deepseek-v4-pro.env.example config/deepseek-v4-pro.env
${EDITOR:-vi} config/deepseek-v4-pro.env

APPTAINER_BUILD_MODE=admin-wrapper \
  IMAGE_PROFILE=deepseek-v4-pro \
  bash scripts/build-image.sh

PCSS_CONFIG="$PWD/config/deepseek-v4-pro.env" bash scripts/download-model.sh
sbatch slurm/deepseek-v4-pro-multinode.sbatch
```

Jeśli preflight lub ładowanie wag zakończy się OOM, użyj ośmiu węzłów bez
zmiany plików:

```bash
sbatch --nodes=8 slurm/deepseek-v4-pro-multinode.sbatch
```

Po starcie odczytaj pierwszy węzeł z logu (`api_node=...`) i zestaw tunel z
lokalnego portu 18001 do portu 8001 tego węzła. Nie kieruj tunelu do dowolnego
workera: endpoint HTTP istnieje tylko na pierwszym węźle.

Oba modele można tunelować jednym helperem. Nazwę węzła Qwena odczytaj przez
`squeue`, a nazwę głównego węzła DeepSeeka z `api_node` w jego logu:

```bash
bash scripts/tunnel-models-ssh.sh QWEN_NODE DEEPSEEK_API_NODE
```

Helper wystawia lokalnie Qwena na `127.0.0.1:18000` i DeepSeeka na
`127.0.0.1:18001`. Jeśli oba serwery są na tym samym węźle, używa jednego
połączenia SSH; jeśli na różnych, utrzymuje dwa połączenia przez ten sam
`ProxyJump`.

Po uruchomieniu tuneli ponownie wykonaj instalator routera Codex. Zachowuje on
modele GPT i dodaje oba modele PCSS do wspólnego selektora:

```bash
# WSL / Codex CLI
bash scripts/setup-codex-router.sh install

# Windows PowerShell / Codex Desktop
.\scripts\setup-codex-router.ps1
```

DeepSeek pojawia się jako `DeepSeek-V4-Pro-0813 (PCSS 16xH100)` z limitem
200000 tokenów. Jego obecność na liście nie wymaga, aby job był stale aktywny;
próba użycia modelu bez działającego tunelu zwróci błąd połączenia, nie usuwa
jednak GPT, Qwena ani historii zadań.

Profil jest celowo oddzielony od działającego Qwen3.8-27B. Ma osobny obraz,
checkpoint, port i plik konfiguracyjny. Przed uznaniem wdrożenia za gotowe log
NCCL musi potwierdzić transport InfiniBand/GDRDMA, a testy `/health`,
`/v1/models`, chat/tool call i Responses API muszą przejść przez tunel.
Katalogi JIT Triton, TileLang i DeepGEMM są tworzone lokalnie w `/tmp` każdego
węzła dla konkretnego joba. Nie wolno przenosić ich na współdzielony NFS:
równoległa kompilacja przez 16 rang może wtedy powodować `Stale file handle`
i asercję DeepGEMM `runtime != nullptr`.

Domyślny profil 16xH100 uruchamia pierwszy preflight z
`MAX_NUM_BATCHED_TOKENS=512` i bez DSpark. Wagi zajmują około 82 GiB na każdej
H100; wartość 16384 z recepty H200 powoduje podczas dummy-run próbę dodatkowej
alokacji około 42 GiB i kończy się OOM. Po potwierdzeniu zdrowego API można
ustawić `H100_SAFE_PROFILE=0`, włączyć DSpark i stopniowo podnosić batch albo
przejść na osiem węzłów.

Pierwsze cztery punkty potwierdzają uruchomienie. Dopiero punkt piąty
potwierdza, że parser tool calls i Responses API są zgodne z Codexem.

## Źródła techniczne

- [vLLM + Codex](https://docs.vllm.ai/en/latest/serving/integrations/codex/)
- [vLLM OpenAI-compatible server](https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/)
- [Apptainer GPU support](https://apptainer.org/docs/user/main/gpu.html)
- [Apptainer definition files](https://apptainer.org/user-docs/master/definition_files.html)
- [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B)
- [codex-shim](https://github.com/0xSero/codex-shim) — router GPT/BYOK (MIT).
- [codex-deepseek-bridge](https://github.com/JetXu-LLM/codex-deepseek-bridge)
  — źródło odwracalnej poprawki Desktop (Apache-2.0).
