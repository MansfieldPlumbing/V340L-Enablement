# Stock llama-bench Gemma die-scaling receipt

**Date:** 2026-09-29  
**Model:** `C:\Models\gemma-4-E4B-it-Q4_K_M.gguf`  
**Build:** stock llama.cpp / ggml commit `4da633776`, build 11223  
**Command:** `llama-bench -ngl 999 -sm layer -ncmoe 0 -ctk q4_0 -ctv q4_0 -fa on --no-host 1 -p 512 -n 128 -r 3 -o json`  
**Benchmark order:** 1 die, 2 dies, 3 dies, 4 dies. Each run was a separate sequential `llama-bench.exe` process. No interception probe or host configuration mutation was used. The `devices` field selected only the listed V340 Vulkan endpoints; Vulkan0 (Quadro P2000) was not selected.

## Results

Rates are llama-bench means ± sample standard deviation across three repetitions.

| V340 dies selected | Vulkan devices | Prompt (512 tokens), tok/s | Generation (128 tokens), tok/s | Gen rate vs previous die count |
|---:|---|---:|---:|---:|
| 1 | `Vulkan1` | 405.521 ± 0.275 | 40.010 ± 0.046 | — |
| 2 | `Vulkan1/Vulkan2` | 404.099 ± 0.505 | 20.418 ± 0.083 | −49.0% |
| 3 | `Vulkan1/Vulkan2/Vulkan3` | 401.106 ± 0.672 | 16.178 ± 0.014 | −20.8% |
| 4 | `Vulkan1/Vulkan2/Vulkan3/Vulkan4` | 395.445 ± 0.756 | 14.251 ± 0.020 | −11.9% |

The measured stock generation curve descends at each added die, with the largest drop from one to two dies. It does not halve at every added die in this run. Prompt throughput also declines modestly as devices are added. These are end-to-end `llama-bench` results, not isolated transfer timings.

## Reproduction details

- Model size: 4,961,343,656 bytes; reported model type: Gemma 4 E4B Q4_K Medium.
- `devices` and `tensor_split` per run: `Vulkan1` / `1.00`; `Vulkan1/Vulkan2` / `1.00/1.00`; `Vulkan1/Vulkan2/Vulkan3` / `1.00/1.00/1.00`; `Vulkan1/Vulkan2/Vulkan3/Vulkan4` / `1.00/1.00/1.00/1.00`.
- All runs reported `n_gpu_layers=999`, `split_mode=layer`, `n_cpu_moe=0`, `type_k=q4_0`, `type_v=q4_0`, `flash_attn=1`, and `no_host=true`.
- llama-bench listed the P2000 in the machine-wide `gpu_info` inventory, but it was not present in any run's selected `devices` value.
- Raw JSON and loader output are preserved in [stock-gemma-die-scaling-2026-09-29.txt](stock-gemma-die-scaling-2026-09-29.txt).
