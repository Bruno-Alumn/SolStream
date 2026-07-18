# SolStream — VM Research for Native Windows Testing

## The Problem
Native SolStream components (D3D11, WinRT, SendInput, named pipe ACLs) need a real Windows desktop with GPU. A remote terminal can't provide these directly.

## Options Analyzed

| Option | GPU/D3D11 | Desktop | Cost | Complexity |
|---|---|---|---|---|
| **QEMU** (local) | ❌ WARP only | ✅ VNC | Free | Hard |
| **Hyper-V GPU-PV** (local) | ✅ Native vGPU | ✅ Enhanced session | Free | Medium |
| **Cloud VM** (AWS/Azure) | ✅ Dedicated GPU | ⚠️ Locks on RDP disconnect | ~$0.75+/hr | Medium |
| **Docker Windows container** | ⚠️ Compute only | ❌ Session 0 | Free | Hard |
| **MCP server wrapper** | ⚠️ Depends on backend | ✅ | Free | Easy |

## ✅ Recommendation: Local Hyper-V + GPU Partitioning

**Winner for SolStream** — your machine has exactly what's needed:
- **Windows 11 Pro** → Hyper-V available
- **NVIDIA RTX 4070 SUPER** → GPU-PV compatible for D3D11 acceleration in VM
- No ongoing cost
- Active desktop persists (not locked on disconnect like cloud RDP)

### How I'd Control It

Hyper-V can be controlled entirely via PowerShell from my terminal tool. No MCP server needed — I already have the terminal:

```powershell
# Create VM with GPU-PV
New-VM -Name SolStreamTest -MemoryGB 8 -BootDevice VHD
Add-VMGpuPartitionAdapter -VMName SolStreamTest
Set-VMGpuPartitionAdapter -VMName SolStreamTest -MinPartitionVRAM 80000000

# Start VM
Start-VM SolStreamTest

# Execute test inside VM (PowerShell Direct, no network needed)
Invoke-Command -VMName SolStreamTest -ScriptBlock {
    .\CaptureHelper.exe --test shared-texture
}

# Copy test binaries to VM
Copy-VMFile SolStreamTest -SourcePath .\build\CaptureHelper.exe `
    -DestinationPath C:\Tests\CaptureHelper.exe -CreateFullPath -FileSource Host

# Stop VM
Stop-VM SolStreamTest
```

### What I Can Test With This

| Component | Previously | With Hyper-V VM |
|---|---|---|
| D3D11 shared texture | ❌ Mock only | ✅ Real GPU with keyed mutex |
| WinRT capture | ❌ Mock only | ✅ Real `CreateForWindow` |
| SendInput injection | ❌ Mock only | ✅ Real desktop focus |
| Named pipe ACLs | ❌ Cannot validate | ✅ Real DACL enforcement |
| Clipboard WS | ✅ Already testable | ✅ (same) |
| UDP crypto | ✅ Already testable | ✅ (same) |

### Setup Steps Needed (you do once)

1. Enable Hyper-V: `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All`
2. Create internal virtual switch for host-VM communication
3. Install Windows 10/11 in a VM (evaluate edition works)
4. Enable GPU-PV: `Add-VMGpuPartitionAdapter` + registry settings in guest
5. Enable PowerShell Direct (automatic with Hyper-V)
6. Enable Auto-Logon in guest for persistent desktop

Then I handle everything else — build the code, copy it into the VM, execute tests, read results, fix bugs, repeat.
