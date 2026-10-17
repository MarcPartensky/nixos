# Steam Deck LLM Service - Usage Guide

## Enable in your configuration

The service is already imported in `profiles/deck/configuration.nix`. Enable it by adding:

```nix
{ config, lib, pkgs, ... }: {
  services.llm-steamdeck = {
    enable = true;

    # Optional: customize model (defaults to Qwen3.5-9B Q4_K_M)
    # modelRepo = "bartowski/Qwen_Qwen3.5-9B-GGUF";
    # modelFile = "Qwen3.5-9B-Q4_K_M.gguf";
    # contextSize = 8192;

    # Optional: server settings
    # port = 8080;
    # host = "0.0.0.0";  # Use "127.0.0.1" for local-only

    # Optional: performance tuning
    # gpuLayers = 99;        # All layers to GPU (Vulkan)
    # threads = 8;           # Steam Deck has 8 cores
    # batchSize = 512;
    # ubatchSize = 512;
    # flashAttn = true;

    # Optional: sampling defaults
    # temperature = 0.7;
    # topP = 0.95;
    # topK = 20;
    # repeatPenalty = 1.1;

    # Optional: extra llama-server args
    # extraArgs = [ "--reasoning" "on" ];  # Enable Qwen3.5 thinking mode
  };
}
```

## Model options

| Model | Repo | File | Size | Notes |
|-------|------|------|------|-------|
| **Qwen3.5-9B Q4_K_M** (default) | `bartowski/Qwen_Qwen3.5-9B-GGUF` | `Qwen3.5-9B-Q4_K_M.gguf` | ~6.17 GB | Best quality/speed balance |
| Qwen3.5-9B Q4_K_M (TheStageAI) | `TheStageAI/Qwen3.5-9B-GGUF` | `Qwen3.5-9B-M-TS-Q4_K_M.gguf` | ~5.06 GB | Smaller, slightly lower quality |
| Qwen3.5-9B Q5_K_M | `bartowski/Qwen_Qwen3.5-9B-GGUF` | `Qwen3.5-9B-Q5_K_M.gguf` | ~7.11 GB | Higher quality, more VRAM |
| Qwen3.5-9B Q3_K_M | `bartowski/Qwen_Qwen3.5-9B-GGUF` | `Qwen3.5-9B-Q3_K_M.gguf` | ~5.18 GB | Lower quality, faster |

## Service management

```bash
# Check status
systemctl status llm-steamdeck

# View logs
journalctl -u llm-steamdeck -f

# Restart
systemctl restart llm-steamdeck

# Stop
systemctl stop llm-steamdeck

# Force model re-download
rm -rf /var/lib/llm-steamdeck && systemctl restart llm-steamdeck-download llm-steamdeck
```

## API usage

The server exposes an OpenAI-compatible API at `http://deck:8080/v1` (or `localhost:8080` from the Deck).

### Chat completions

```bash
curl -X POST http://deck:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.5-9b",
    "messages": [
      {"role": "user", "content": "Explain quantum computing in simple terms"}
    ],
    "temperature": 0.7,
    "max_tokens": 512
  }'
```

### With thinking/reasoning mode (Qwen3.5)

```bash
curl -X POST http://deck:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.5-9b",
    "messages": [
      {"role": "user", "content": "Solve this step by step: 25 * 37"}
    ],
    "extra_body": {
      "chat_template_kwargs": {"enable_thinking": true}
    }
  }'
```

### Streaming

```bash
curl -X POST http://deck:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.5-9b",
    "messages": [{"role": "user", "content": "Write a haiku about Steam Deck"}],
    "stream": true
  }'
```

### Web UI

Open `http://deck:8080` in a browser for the built-in llama.cpp web interface.

## Performance notes for Steam Deck

- **Expected speed**: ~10-13 tokens/s (Qwen3.5-9B Q4_K_M, all layers on GPU via Vulkan/RADV)
- **Prefill latency**: ~30-60s for 4000-token prompts (weak GPU compute)
- **RAM usage**: ~8-9 GB total (model + KV cache + OS)
- **Headless mode**: For max context (16K), run without gamescope/desktop:
  ```bash
  systemctl stop plasma-plasma-kwin_wayland@0.service sddm
  # Then start llm-steamdeck
  ```
- **Vulkan**: Uses RADV (Mesa) - ensure `hardware.opengl.enable = true` and `hardware.opengl.driSupport = true`

## Troubleshooting

### OOM / crash on start
- Reduce `gpuLayers` to 80 or lower
- Reduce `contextSize` to 4096
- Use smaller quantization (Q3_K_M)

### Slow prefill
- This is normal for Steam Deck GPU (8 CU RDNA 2, ~1.6 TFLOPS)
- Keep prompts under 2000 tokens for responsive chat
- Use smaller `batchSize` / `ubatchSize` (256)

### Vulkan not working
```bash
# Verify Vulkan
vulkaninfo | grep -E "(GPU|deviceName|driver)"

# Check RADV
RADV_PERFTEST=aco,nggc,mesh_shaders AMD_DEBUG=w32ge,w32cs \
  llama-server --model /var/lib/llm-steamdeck/... -ngl 99 --port 8081
```

### Model download fails
- Check network connectivity
- For gated models, set `hfToken` via sops secret
- Manual download:
  ```bash
  huggingface-cli download bartowski/Qwen_Qwen3.5-9B-GGUF \
    --include "Qwen3.5-9B-Q4_K_M.gguf" \
    --local-dir /var/lib/llm-steamdeck/bartowski_Qwen_Qwen3.5-9B-GGUF
  ```

## Integration with Hermes / other tools

Add to your Hermes/OpenAI client config:
```yaml
providers:
  - name: "deck-qwen"
    type: "openai"
    base_url: "http://deck.local:8080/v1"
    api_key: "dummy"  # llama-server doesn't require auth
    models: ["qwen3.5-9b"]
```

## Updating the model

```bash
# Stop service
systemctl stop llm-steamdeck

# Remove old model
rm -rf /var/lib/llm-steamdeck/bartowski_Qwen_Qwen3.5-9B-GGUF

# Restart (triggers re-download)
systemctl start llm-steamdeck-download llm-steamdeck
```