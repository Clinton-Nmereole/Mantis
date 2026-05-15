# Cloud Tuning Guide for Mantis

This document explains how to run serious parameter tuning for Mantis on cloud infrastructure. While local tuning is fine for exploration, TCEC-level strength requires validation with **10,000+ games at long time controls** — something that takes weeks on a single desktop but only a day or two in the cloud.

---

## Overview

| Stage | Games | TC | Purpose | Where |
|-------|-------|-----|---------|-------|
| Local exploration | 30–80 | 100ms | Find promising directions | Your desktop |
| Local verify | 100 | 3+0 | Confirm candidates | Your desktop |
| Cloud tuning | 2,000–10,000 | 3+0 or 5+0.05 | Statistically robust tuning | Cloud |
| Final validation | 1,000+ | 10+0.1 or 60+0.6 | TCEC-like conditions | Cloud |

---

## Option 1: Google Cloud Platform (Recommended)

### Setup

1. Create a GCP account (free $300 credit for new users)
2. Enable Compute Engine API
3. Create a VM instance:
   - **Machine type**: `c2-standard-8` (8 vCPU, 32 GB) or `c2-standard-16`
   - **OS**: Ubuntu 22.04 LTS
   - **Disk**: 50 GB SSD persistent disk
   - **Preemptible**: Yes (60–70% cheaper, fine for batch tuning)

### Launch Script

```bash
#!/bin/bash
# launch_tuning_gcp.sh

gcloud compute instances create mantis-tune-1 \
  --zone=us-central1-a \
  --machine-type=c2-standard-8 \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --preemptible \
  --metadata-from-file startup-script=setup_tuner.sh
```

### Setup Script (setup_tuner.sh)

```bash
#!/bin/bash
# Run on VM startup

apt-get update
apt-get install -y git python3 python3-venv build-essential clang llvm

# Clone Mantis
cd /opt
git clone https://github.com/yourname/Mantis.git
cd Mantis

# Build baseline
./build_safe.sh
cp mantis mantis_baseline

# Setup Python environment
python3 -m venv venv
source venv/bin/activate
pip install nevergrad

# Start tuning with 100 evals (takes ~8 hours on 8 cores)
python3 nevergrad_tuner.py \
  --budget 100 \
  --games 20 \
  --movetime 200 \
  --concurrency 8 \
  --output best_params_cloud.json \
  > tuning_cloud.log 2>&1 &
```

### Cost Estimate

| Instance | vCPUs | Cost/hr | 24hr run | 100 evals (~8hr) |
|----------|-------|---------|----------|-----------------|
| c2-standard-8 | 8 | $0.21 | $5.04 | $1.68 |
| c2-standard-16 | 16 | $0.42 | $10.08 | $3.36 |
| Preemptible (×0.3) | 8 | $0.06 | $1.44 | $0.48 |

**For a full 10,000-game SPRT validation at 3+0:**
- 16 cores, ~20 hours, preemptible: **~$2.50**

---

## Option 2: AWS EC2 Spot Instances

### Setup

```bash
# Launch spot instance
aws ec2 run-instances \
  --image-id ami-0c7217cdde317cfec \
  --instance-type c6i.2xlarge \
  --key-name your-key \
  --spot-options '{"SpotInstanceType": "one-time"}' \
  --user-data file://setup_tuner.sh
```

### Cost

| Instance | vCPUs | Spot Cost/hr | 24hr |
|----------|-------|--------------|------|
| c6i.2xlarge | 8 | $0.06 | $1.44 |
| c6i.4xlarge | 16 | $0.12 | $2.88 |

---

## Option 3: Modal (Serverless)

Modal runs your code serverlessly and scales automatically. Best for "fire and forget" tuning.

### modal_tuner.py

```python
import modal
import subprocess
import os

stub = modal.Stub("mantis-tuner")
image = modal.Image.debian_slim().apt_install(
    "git", "clang", "llvm", "python3", "python3-venv"
).pip_install("nevergrad")

@stub.function(image=image, cpu=8, timeout=86400)
def run_tuning_iteration(params: dict) -> float:
    """Run one tuning evaluation in the cloud."""
    # Mantis source would be baked into the image or pulled from Git
    os.chdir("/mantis")
    
    # Modify params, build, evaluate
    # ... (same logic as nevergrad_tuner.py)
    
    return win_pct

@stub.local_entrypoint
def main():
    import nevergrad as ng
    
    # Run 100 evaluations, each on its own Modal container
    optimizer = ng.optimizers.NGOpt(parametrization=..., budget=100)
    
    for _ in range(100):
        candidate = optimizer.ask()
        score = run_tuning_iteration.remote(candidate.value)
        optimizer.tell(candidate, -score)
```

### Cost

Modal charges per CPU-second:
- ~$0.0001 per CPU-second
- 8 cores × 10 min × 100 evals = 480,000 CPU-seconds
- **~$48** for 100 evaluations

More expensive than raw EC2/GCP but zero setup and automatic scaling.

---

## Option 4: RunPod (GPU/CPU Spot)

RunPod offers very cheap CPU spot instances:
- 8 vCPU, 32 GB: **$0.05/hr**
- 16 vCPU, 64 GB: **$0.10/hr**

Best for: "I want a cheap Linux box for a weekend."

---

## Distributed Tuning with Multiple Machines

For serious tuning (TCEC prep), run multiple VMs in parallel:

```bash
# Launch 5 VMs
for i in {1..5}; do
  gcloud compute instances create mantis-tune-$i \
    --zone=us-central1-a \
    --machine-type=c2-standard-8 \
    --preemptible \
    --metadata-from-file startup-script=setup_tuner.sh &
done

# Each VM runs independent nevergrad evaluations
# Aggregate results manually or via a shared GCS bucket
```

With 5 VMs × 8 cores = 40 concurrent games:
- 100 evals × 20 games at 200ms: **~2 hours**
- Cost: 5 × $0.06 × 2 = **$0.60**

---

## Recommended TCEC Prep Workflow

### Phase 1: Local Screening (Your Desktop)
```bash
# Find promising regions of parameter space
python3 nevergrad_tuner.py --budget 30 --games 10 --movetime 100
```
**Time:** 3–4 hours | **Cost:** $0

### Phase 2: Cloud Refinement (GCP/AWS)
```bash
# Run 100 evaluations with more games per eval
python3 nevergrad_tuner.py \
  --budget 100 \
  --games 20 \
  --movetime 200 \
  --concurrency 8
```
**Time:** 6–8 hours | **Cost:** ~$1–2

### Phase 3: Cloud Verification (SPRT)
```bash
# Run SPRT at 3+0 to confirm the best candidate
python3 selfplay.py \
  --engine-a ./mantis \
  --engine-b ./mantis_baseline \
  --verify \
  --concurrency 8 \
  --openings openings.epd
```
**Time:** Until SPRT decides (usually 50–150 games) | **Cost:** ~$0.50

### Phase 4: Large-Scale Validation (Distributed)
```bash
# Run 1,000+ games at 10+0.1 to confirm scaling
# Use 5+ VMs in parallel, aggregate results
cutechess-cli \
  -engine cmd=./mantis \
  -engine cmd=./mantis_baseline \
  -each tc=10+0.1 -games 1000 \
  -concurrency 8
```
**Time:** 1–2 days | **Cost:** ~$5–10

---

## Key Lessons from Stockfish Fishtest

1. **Time control scaling matters**: Parameters tuned at blitz often regress at classical. Always verify at TCEC-like TC (60+0.6 or longer).

2. **SPRT saves 30–40% of games**: Don't run fixed-length matches. Use SPRT to stop early when the result is clear.

3. **Draw rate affects SPRT power**: At fast TC, draw rates are ~25%. At classical, ~50%. Higher draw rates require more games for the same statistical power.

4. **Concurrency is king**: A 16-core VM is 4× faster than a 4-core VM for the same price (on preemptible instances).

5. **Never tune and change code at the same time**: Each tuning run should test one concept. If you change both LMR and NMP, you won't know which helped.

---

## Checklist Before TCEC Submission

- [ ] Engine passes `bench` without changes (functional stability)
- [ ] Parameters verified with SPRT at 3+0 or longer
- [ ] No illegal moves in 1,000+ test games
- [ ] Time management tested with increment (TCEC uses increment)
- [ ] Multi-threaded search tested (TCEC uses 176 threads)
- [ ] Opening book tested with TCEC openings
- [ ] Syzygy tablebases tested if used
- [ ] Ponder mode works correctly
- [ ] UCI `go infinite` + `stop` works reliably

---

## Quick Reference: Cloud Commands

```bash
# GCP: SSH into VM
gcloud compute ssh mantis-tune-1 --zone=us-central1-a

# GCP: Stream logs
gcloud compute ssh mantis-tune-1 --zone=us-central1-a -- tail -f /opt/Mantis/tuning_cloud.log

# GCP: Copy results back
gcloud compute scp mantis-tune-1:/opt/Mantis/best_params_cloud.json . --zone=us-central1-a

# GCP: Delete all tuning VMs
gcloud compute instances delete mantis-tune-1 mantis-tune-2 ... --zone=us-central1-a
```

---

*Last updated: 2026-05-15*
