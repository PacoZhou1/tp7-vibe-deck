"""
Open Speech ASR - Legacy Local Inference Service
可选旧栈：SenseVoice ASR + Gemma E4B 纠错。
"""
import os
import sys

# Force using bundled site-packages (not user ~/.local/)
os.environ.setdefault("PYTHONNOUSERSITE", "1")
import gc
import json
import logging
import re
import subprocess
import tempfile
import asyncio
from contextlib import asynccontextmanager
from typing import Optional, Dict, Any
from datetime import datetime

import numpy as np
from fastapi import FastAPI, HTTPException, UploadFile, File, Body
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# ============================================================================
# Data Models
# ============================================================================

class CorrectTextRequest(BaseModel):
    text: str
    context: Optional[str] = None
    vocabulary: Optional[Any] = None
    model: str = "gemma-e4b-q4"

class CorrectTextResponse(BaseModel):
    correctedText: str
    changes: list = []
    confidence: float = 0.0
    cached: bool = False
    processingTimeMs: int = 0

class TranscribeResponse(BaseModel):
    rawText: str
    correctedText: Optional[str] = None
    language: str
    confidence: float
    processingTimeMs: int
    ttftMs: int
    asrModel: str = "sensevoice"

class MemoryCleanupRequest(BaseModel):
    reason: Optional[str] = None
    globalSoftLimitMb: Optional[float] = None
    peerMlxTrackedMemoryMb: float = 0.0
    peerMemoryFootprintMb: Optional[float] = None

class HealthResponse(BaseModel):
    status: str
    processId: int
    sessionToken: str
    modelLoaded: bool
    localLLMEnabled: bool = True
    asrLoaded: bool
    memoryUsageMb: float
    memorySoftLimitMb: float
    memoryCleanupThresholdMb: float
    memoryRestartThresholdMb: float
    needsMemoryCleanup: bool = False
    needsBackendRestart: bool = False
    mlxTrackedMemoryMb: Optional[float] = None
    mlxActiveMemoryMb: Optional[float] = None
    mlxCacheMemoryMb: Optional[float] = None
    mlxCacheLimitMb: Optional[float] = None
    mlxMemoryLimitMb: Optional[float] = None
    mlxActiveOverSoftLimit: bool = False
    lastMemoryCleanup: Optional[Dict[str, Any]] = None
    timestamp: str

# ============================================================================
# Memory Guard
# ============================================================================

MEMORY_CLEANUP_THRESHOLD_MB = float(
    os.getenv(
        "INFERENCE_MEMORY_SOFT_LIMIT_MB",
        os.getenv("INFERENCE_MEMORY_CLEANUP_THRESHOLD_MB", "8000"),
    )
)
MEMORY_RESTART_THRESHOLD_MB = float(os.getenv("INFERENCE_MEMORY_RESTART_THRESHOLD_MB", "9000"))
MEMORY_MONITOR_INTERVAL_SECONDS = float(os.getenv("INFERENCE_MEMORY_MONITOR_INTERVAL_SECONDS", "10"))
MLX_INITIAL_CACHE_LIMIT_MB = float(os.getenv("INFERENCE_MLX_INITIAL_CACHE_LIMIT_MB", "2048"))
MLX_CACHE_FLOOR_MB = float(os.getenv("INFERENCE_MLX_CACHE_FLOOR_MB", "256"))
MLX_CACHE_HEADROOM_MB = float(os.getenv("INFERENCE_MLX_CACHE_HEADROOM_MB", "512"))
MLX_MEMORY_LIMIT_MB = float(
    os.getenv(
        "INFERENCE_MLX_MEMORY_LIMIT_MB",
        str(max(MEMORY_RESTART_THRESHOLD_MB, MEMORY_CLEANUP_THRESHOLD_MB + MLX_CACHE_HEADROOM_MB)),
    )
)
MLX_MAX_KV_SIZE = int(os.getenv("INFERENCE_MLX_MAX_KV_SIZE", "768"))
MLX_MIN_TOKENS = int(os.getenv("INFERENCE_MLX_MIN_TOKENS", "160"))
MLX_MAX_TOKENS = int(os.getenv("INFERENCE_MLX_MAX_TOKENS", "1024"))
MLX_OUTPUT_TOKEN_RATIO = float(os.getenv("INFERENCE_MLX_OUTPUT_TOKEN_RATIO", "1.35"))
MLX_KV_BITS = int(os.getenv("INFERENCE_MLX_KV_BITS", "0"))
LOCAL_LLM_ENABLED = os.getenv("INFERENCE_DISABLE_LOCAL_LLM", "0") != "1"
LOCAL_ASR_ENABLED = os.getenv("INFERENCE_DISABLE_SENSEVOICE_ASR", "0") != "1"
BACKEND_SESSION_TOKEN = os.getenv("INFERENCE_SESSION_TOKEN", "")


class MemoryGuard:
    """Keep MLX transient buffers from growing without restarting the model."""

    threshold_mb = MEMORY_CLEANUP_THRESHOLD_MB
    restart_threshold_mb = MEMORY_RESTART_THRESHOLD_MB
    cache_floor_mb = MLX_CACHE_FLOOR_MB
    cache_headroom_mb = MLX_CACHE_HEADROOM_MB
    initial_cache_limit_mb = MLX_INITIAL_CACHE_LIMIT_MB
    memory_limit_mb = MLX_MEMORY_LIMIT_MB
    current_cache_limit_mb: Optional[float] = None
    current_memory_limit_mb: Optional[float] = None
    last_cleanup: Optional[Dict[str, Any]] = None

    @classmethod
    def process_memory_mb(cls) -> float:
        try:
            import psutil
            return psutil.Process(os.getpid()).memory_info().rss / 1_000_000
        except Exception:
            return 0.0

    @classmethod
    def mlx_memory_stats(cls) -> Dict[str, Optional[float]]:
        stats: Dict[str, Optional[float]] = {
            "mlxActiveMemoryMb": None,
            "mlxCacheMemoryMb": None,
            "mlxCacheLimitMb": cls.current_cache_limit_mb,
            "mlxMemoryLimitMb": cls.current_memory_limit_mb,
        }
        try:
            import mlx.core as mx
            if hasattr(mx, "get_active_memory") and hasattr(mx, "get_cache_memory"):
                active = mx.get_active_memory()
                cache = mx.get_cache_memory()
            else:
                active = mx.metal.get_active_memory()
                cache = mx.metal.get_cache_memory()
            stats["mlxActiveMemoryMb"] = active / 1_000_000
            stats["mlxCacheMemoryMb"] = cache / 1_000_000
            stats["mlxCacheLimitMb"] = cls._cache_limit_mb(mx)
            stats["mlxMemoryLimitMb"] = cls._memory_limit_mb(mx)
        except Exception:
            pass
        return stats

    @classmethod
    def snapshot(cls) -> Dict[str, Any]:
        mlx = cls.mlx_memory_stats()
        tracked = cls.tracked_mlx_memory_mb(mlx)
        memory_usage = cls.process_memory_mb()
        cache = mlx.get("mlxCacheMemoryMb") or 0.0
        active = mlx.get("mlxActiveMemoryMb") or 0.0
        tracked_value = tracked or 0.0
        return {
            "memoryUsageMb": memory_usage,
            "memorySoftLimitMb": cls.threshold_mb,
            "memoryCleanupThresholdMb": cls.threshold_mb,
            "memoryRestartThresholdMb": cls.restart_threshold_mb,
            "needsMemoryCleanup": (
                memory_usage >= cls.threshold_mb or
                cache >= cls.threshold_mb or
                tracked_value >= cls.threshold_mb
            ),
            "needsBackendRestart": (
                active >= cls.restart_threshold_mb or
                (
                    memory_usage >= cls.restart_threshold_mb and
                    cache <= max(cls.cache_floor_mb, cls.cache_headroom_mb)
                )
            ),
            "mlxTrackedMemoryMb": tracked,
            "mlxActiveOverSoftLimit": active >= cls.threshold_mb,
            **mlx,
            "lastMemoryCleanup": cls.last_cleanup,
        }

    @classmethod
    def configure_mlx_limits(cls):
        try:
            import mlx.core as mx
            cls._set_memory_limit_mb(mx, cls.memory_limit_mb)
            cls._set_cache_limit_mb(mx, min(cls.initial_cache_limit_mb, cls.threshold_mb))
            logger.info(
                "MLX memory policy configured: soft=%.0f MB, hard=%.0f MB, memory_limit=%.0f MB, initial_cache_limit=%.0f MB",
                cls.threshold_mb,
                cls.restart_threshold_mb,
                cls.current_memory_limit_mb or cls.memory_limit_mb,
                cls.current_cache_limit_mb or cls.initial_cache_limit_mb,
            )
        except Exception as e:
            logger.warning(f"Unable to configure MLX memory policy: {e}")

    @classmethod
    def maybe_cleanup(
        cls,
        reason: str,
        force: bool = False,
        global_soft_limit_mb: Optional[float] = None,
        peer_tracked_memory_mb: float = 0.0,
        peer_memory_footprint_mb: Optional[float] = None,
    ) -> bool:
        before_rss = cls.process_memory_mb()
        before_mlx = cls.mlx_memory_stats()
        before_active = before_mlx.get("mlxActiveMemoryMb") or 0.0
        before_cache = before_mlx.get("mlxCacheMemoryMb") or 0.0
        before_tracked = cls.tracked_mlx_memory_mb(before_mlx) or 0.0
        peer_budget_mb = max(0.0, peer_memory_footprint_mb or peer_tracked_memory_mb)
        effective_soft_limit_mb = cls._effective_soft_limit_mb(
            global_soft_limit_mb=global_soft_limit_mb,
            peer_memory_footprint_mb=peer_budget_mb,
        )
        target_cache_limit_mb = cls._target_cache_limit_mb(before_active, effective_soft_limit_mb)
        cache_limit_before = before_mlx.get("mlxCacheLimitMb")
        should_cleanup = (
            force or
            before_rss >= effective_soft_limit_mb or
            before_cache >= effective_soft_limit_mb or
            before_tracked >= effective_soft_limit_mb or
            before_cache > target_cache_limit_mb
        )
        if not should_cleanup:
            return False

        log_cleanup = logger.info if force else logger.warning
        log_cleanup(
            "Memory cleanup triggered (%s): rss=%.0f MB, mlx_tracked=%.0f MB, peer_budget=%.0f MB, mlx_active=%s MB, mlx_cache=%s MB, target_cache_limit=%.0f MB, local_soft=%.0f MB, global_soft=%s MB",
            reason,
            before_rss,
            before_tracked,
            peer_budget_mb,
            cls._fmt(before_mlx.get("mlxActiveMemoryMb")),
            cls._fmt(before_mlx.get("mlxCacheMemoryMb")),
            target_cache_limit_mb,
            effective_soft_limit_mb,
            cls._fmt(global_soft_limit_mb),
        )

        try:
            import mlx.core as mx
            cls._set_cache_limit_mb(mx, target_cache_limit_mb)
            cls._clear_mlx_cache(mx)
        except Exception as e:
            logger.warning(f"MLX cache cleanup failed: {e}")

        cls._clear_torch_cache()
        gc.collect()
        cls._pressure_relief()
        after_rss = cls.process_memory_mb()
        after_mlx = cls.mlx_memory_stats()
        after_tracked = cls.tracked_mlx_memory_mb(after_mlx)
        after_active = after_mlx.get("mlxActiveMemoryMb") or 0.0
        after_cache = after_mlx.get("mlxCacheMemoryMb") or 0.0
        restart_recommended = (
            after_active >= cls.restart_threshold_mb or
            (
                after_rss >= cls.restart_threshold_mb and
                after_cache <= max(cls.cache_floor_mb, cls.cache_headroom_mb)
            )
        )
        cls.last_cleanup = {
            "timestamp": datetime.now().isoformat(),
            "reason": reason,
            "forced": force,
            "beforeMemoryUsageMb": round(before_rss, 1),
            "afterMemoryUsageMb": round(after_rss, 1),
            "beforeMlxTrackedMemoryMb": cls._round(before_tracked),
            "afterMlxTrackedMemoryMb": cls._round(after_tracked),
            "beforeMlxActiveMemoryMb": cls._round(before_mlx.get("mlxActiveMemoryMb")),
            "afterMlxActiveMemoryMb": cls._round(after_mlx.get("mlxActiveMemoryMb")),
            "beforeMlxCacheMemoryMb": cls._round(before_mlx.get("mlxCacheMemoryMb")),
            "afterMlxCacheMemoryMb": cls._round(after_mlx.get("mlxCacheMemoryMb")),
            "beforeMlxCacheLimitMb": cls._round(cache_limit_before),
            "afterMlxCacheLimitMb": cls._round(after_mlx.get("mlxCacheLimitMb")),
            "targetMlxCacheLimitMb": cls._round(target_cache_limit_mb),
            "memorySoftLimitMb": effective_soft_limit_mb,
            "globalMemorySoftLimitMb": cls._round(global_soft_limit_mb),
            "peerMlxTrackedMemoryMb": cls._round(peer_tracked_memory_mb),
            "peerMemoryFootprintMb": cls._round(peer_budget_mb),
            "memoryRestartThresholdMb": cls.restart_threshold_mb,
            "triggeredByRss": before_rss >= effective_soft_limit_mb,
            "triggeredByMlxTracked": before_tracked >= effective_soft_limit_mb,
            "triggeredByMlxActive": before_active >= effective_soft_limit_mb,
            "triggeredByMlxCache": before_cache >= effective_soft_limit_mb,
            "restartRecommended": restart_recommended,
        }
        logger.info(
            "Memory cleanup complete: rss %.0f -> %.0f MB, mlx_tracked %.0f -> %s MB, mlx_cache %s -> %s MB, cache_limit %s -> %s MB",
            before_rss,
            after_rss,
            before_tracked,
            cls._fmt(after_tracked),
            cls._fmt(before_mlx.get("mlxCacheMemoryMb")),
            cls._fmt(after_mlx.get("mlxCacheMemoryMb")),
            cls._fmt(cache_limit_before),
            cls._fmt(after_mlx.get("mlxCacheLimitMb")),
        )
        if after_active >= effective_soft_limit_mb:
            logger.warning(
                "MLX active memory remains above soft limit after cleanup: active=%.0f MB, soft=%.0f MB. Active model tensors cannot be paged out safely; restart remains the last-resort path.",
                after_active,
                effective_soft_limit_mb,
            )
        return True

    @classmethod
    async def monitor_loop(cls):
        while True:
            await asyncio.sleep(MEMORY_MONITOR_INTERVAL_SECONDS)
            cls.maybe_cleanup("background-monitor")

    @staticmethod
    def _pressure_relief():
        try:
            import ctypes
            libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            relief = getattr(libc, "malloc_zone_pressure_relief", None)
            if relief is not None:
                relief(None, 0)
        except Exception:
            pass

    @staticmethod
    def _clear_torch_cache():
        if "torch" not in sys.modules:
            return
        try:
            import torch
            if hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):
                torch.mps.empty_cache()
            if hasattr(torch, "cuda") and hasattr(torch.cuda, "empty_cache"):
                torch.cuda.empty_cache()
        except Exception:
            pass

    @classmethod
    def _effective_soft_limit_mb(
        cls,
        global_soft_limit_mb: Optional[float],
        peer_memory_footprint_mb: float,
    ) -> float:
        if global_soft_limit_mb is None or global_soft_limit_mb <= 0:
            return cls.threshold_mb
        return max(0.0, min(cls.threshold_mb, global_soft_limit_mb - max(0.0, peer_memory_footprint_mb)))

    @classmethod
    def _target_cache_limit_mb(cls, active_mb: float, soft_limit_mb: float) -> float:
        remaining = soft_limit_mb - active_mb - cls.cache_headroom_mb
        if remaining <= 0:
            return 0.0
        return max(cls.cache_floor_mb, min(cls.initial_cache_limit_mb, remaining))

    @classmethod
    def _set_cache_limit_mb(cls, mx, limit_mb: float):
        clamped_mb = max(0.0, limit_mb)
        limit_bytes = int(clamped_mb * 1024 * 1024)
        if hasattr(mx, "set_cache_limit"):
            mx.set_cache_limit(limit_bytes)
        else:
            mx.metal.set_cache_limit(limit_bytes)
        cls.current_cache_limit_mb = clamped_mb

    @classmethod
    def _set_memory_limit_mb(cls, mx, limit_mb: float):
        clamped_mb = max(cls.threshold_mb, limit_mb)
        limit_bytes = int(clamped_mb * 1024 * 1024)
        if hasattr(mx, "set_memory_limit"):
            mx.set_memory_limit(limit_bytes)
        else:
            mx.metal.set_memory_limit(limit_bytes)
        cls.current_memory_limit_mb = clamped_mb

    @classmethod
    def _clear_mlx_cache(cls, mx):
        if hasattr(mx, "synchronize"):
            mx.synchronize()
        if hasattr(mx, "clear_cache"):
            mx.clear_cache()
        else:
            mx.metal.clear_cache()

    @classmethod
    def _cache_limit_mb(cls, mx) -> Optional[float]:
        if cls.current_cache_limit_mb is not None:
            return cls.current_cache_limit_mb
        return cls._read_limit_mb(mx, "get_cache_limit", "cache_limit")

    @classmethod
    def _memory_limit_mb(cls, mx) -> Optional[float]:
        if cls.current_memory_limit_mb is not None:
            return cls.current_memory_limit_mb
        return cls._read_limit_mb(mx, "get_memory_limit", "memory_limit")

    @staticmethod
    def _read_limit_mb(mx, function_name: str, attribute_name: str) -> Optional[float]:
        for owner in (mx, getattr(mx, "metal", None)):
            if owner is None:
                continue
            try:
                getter = getattr(owner, function_name, None)
                if getter is not None:
                    return getter() / 1_000_000
                value = getattr(owner, attribute_name, None)
                if isinstance(value, (int, float)):
                    return value / 1_000_000
            except Exception:
                continue
        return None

    @staticmethod
    def _round(value: Optional[float]) -> Optional[float]:
        return None if value is None else round(value, 1)

    @staticmethod
    def _fmt(value: Optional[float]) -> str:
        return "n/a" if value is None else f"{value:.0f}"

    @staticmethod
    def tracked_mlx_memory_mb(stats: Dict[str, Optional[float]]) -> Optional[float]:
        active = stats.get("mlxActiveMemoryMb")
        cache = stats.get("mlxCacheMemoryMb")
        if active is None and cache is None:
            return None
        return (active or 0.0) + (cache or 0.0)

# ============================================================================
# SenseVoice Text Cleaner
# ============================================================================

_SENSEVOICE_TAG_RE = re.compile(r"<\|[^|]*\|>")

def clean_sensevoice_text(text: str) -> str:
    """Strip SenseVoice special tokens like <|zh|>, <|EMO_UNKNOWN|>, <|Speech|>"""
    text = _SENSEVOICE_TAG_RE.sub("", text)
    # Remove leading/trailing noise
    text = text.strip()
    # Remove common artifacts
    text = re.sub(r"<\|woitn\|>", "", text)
    return text or ""

# ============================================================================
# Audio Converter: WebM/Ogg → 16kHz mono WAV (via ffmpeg)
# ============================================================================

def convert_to_wav(input_path: str) -> str:
    """Convert any audio format to 16kHz mono WAV using ffmpeg."""
    output_path = input_path + ".conv.wav"
    cmd = [
        "ffmpeg", "-y", "-i", input_path,
        "-ar", "16000", "-ac", "1", "-sample_fmt", "s16",
        output_path,
    ]
    try:
        subprocess.run(cmd, capture_output=True, check=True, timeout=30)
        return output_path
    except subprocess.CalledProcessError as e:
        logger.error(f"ffmpeg error: {e.stderr.decode() if e.stderr else str(e)}")
        # Fallback: try raw input directly
        return input_path
    except FileNotFoundError:
        logger.warning("ffmpeg not found, trying raw input")
        return input_path

# ============================================================================
# Text Correction Service (Local MLX Gemma 4 E4B)
# ============================================================================

class TextCorrectionService:
    def __init__(self, model_dir: str = None):
        self.model_dir = model_dir
        self.model = None
        self.tokenizer = None
        self.is_loaded = False
        self.load_time_ms = 0

    def load_model(self):
        try:
            t0 = datetime.now()
            from mlx_lm import load
            self.model, self.tokenizer = load(self.model_dir)
            self.is_loaded = True
            self.load_time_ms = int((datetime.now() - t0).total_seconds() * 1000)
            logger.info(f"Gemma 4 E4B loaded in {self.load_time_ms}ms")

            # Lock model memory to prevent swap on low-RAM machines
            if os.getenv("INFERENCE_LOCK_MODEL_MEMORY", "0") == "1":
                self._lock_memory()
            else:
                logger.info("Model memory locking disabled; set INFERENCE_LOCK_MODEL_MEMORY=1 to enable mlockall")

            return True
        except Exception as e:
            logger.error(f"Failed to load Gemma 4: {e}")
            self.is_loaded = False
            return False

    @staticmethod
    def _lock_memory():
        """Lock all current process pages in RAM to prevent swap.
        Uses mlockall(MCL_CURRENT) — tells the kernel to keep all
        currently mapped pages resident and never page them out.
        This is critical on 16GB machines where the 4.9GB model
        could be swapped out by memory pressure."""
        try:
            import ctypes
            import ctypes.util

            libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

            MCL_CURRENT = 1  # Lock all currently mapped pages

            result = libc.mlockall(MCL_CURRENT)
            if result == 0:
                import psutil
                mem = psutil.Process(os.getpid()).memory_info().rss / 1024 / 1024
                logger.info(f"mlockall(MCL_CURRENT) succeeded — {mem:.0f} MB locked in RAM")
            else:
                errno = ctypes.get_errno()
                logger.warning(f"mlockall() failed (errno={errno}); model may be swapped under memory pressure")
        except Exception as e:
            logger.warning(f"mlockall() not available: {e}; model may be swapped under memory pressure")

    def correct_text(self, text: str, context=None, vocabulary=None, custom_prompt: str = "") -> Dict[str, Any]:
        if not text.strip():
            return {"correctedText": text, "changes": [], "confidence": 1.0,
                    "cached": False, "processingTimeMs": 0}
        if not self.is_loaded:
            return {"correctedText": text, "changes": [], "confidence": 0.5,
                    "cached": False, "processingTimeMs": 0}

        t0 = datetime.now()
        try:
            from mlx_lm import generate
            from mlx_lm.sample_utils import make_sampler

            context_hint = ""
            if context and str(context).strip():
                context_hint = f"\\n上下文（仅用于判断语气、术语和指代，不要输出）：{str(context).strip()}"

            vocabulary_constraint = ""
            vocabulary_items = self._normalize_vocabulary(vocabulary)
            if vocabulary_items:
                vocabulary_constraint = (
                    "\\n\\n个人词库硬约束：遇到相关词语时，必须优先使用以下精确写法，"
                    "不要拆分、翻译、改大小写或改拼写："
                    + ", ".join(vocabulary_items)
                )

            # Use custom prompt if provided, otherwise default
            if custom_prompt and custom_prompt.strip():
                system_content = custom_prompt.strip()
            else:
                system_content = (
                    "你是一个运行在系统后台的专业纯文本处理引擎，绝不是对话型 AI。"
                    "你的唯一职责是接收粗略的语音转写文本，并静默输出可直接用于出版或正式沟通的干净文本。\\n\\n"
                    "请严格执行以下操作指令：\\n"
                    "1. 净化杂音：精准剔除所有口语化的无意义停顿词和连接词"
                    "（如'呃'、'那个'、'然后'、'就是说'、'对吧'等）。\\n"
                    "2. 智能纠错：结合上下文逻辑，修正同音错别字和语序混乱。"
                    "正确处理中英文夹杂（Chinglish）的场景，"
                    "确保英文专业术语大小写及拼写正确。\\n"
                    "3. 精准断句：根据语意逻辑，补充准确的标点符号。\\n"
                    "4. 忠于原意：绝不允许改变用户的原始意图、语气，"
                    "更不允许私自扩写或总结内容。\\n"
                    "5. 绝对限制：绝不允许输出任何开场白、解释、确认语或代码块格式。"
                    "例如，绝不能出现'好的'、'修改如下'等字眼。\\n\\n"
                    "仅输出处理后的纯文本结果。"
                )
            if vocabulary_constraint:
                system_content += vocabulary_constraint

            msgs = [
                {"role": "system", "content": system_content},
                {"role": "user", "content": f"输入：{text}{context_hint}\\n输出："},
            ]
            prompt = self.tokenizer.apply_chat_template(
                msgs, tokenize=False, add_generation_prompt=True, enable_thinking=False
            )

            sampler = make_sampler(temp=0.0)
            max_tokens = self._max_generation_tokens(text)
            generation_kwargs = {
                "max_tokens": max_tokens,
                "sampler": sampler,
                "max_kv_size": MLX_MAX_KV_SIZE,
            }
            if MLX_KV_BITS > 0:
                generation_kwargs["kv_bits"] = MLX_KV_BITS
                generation_kwargs["quantized_kv_start"] = 0

            raw = generate(
                self.model,
                self.tokenizer,
                prompt=prompt,
                **generation_kwargs,
            )
            corrected = raw.strip()
            corrected = self._enforce_vocabulary(corrected, vocabulary_items)
            t = int((datetime.now() - t0).total_seconds() * 1000)
            logger.info(
                "Correction (%dms, max_tokens=%d, input_chars=%d, output_chars=%d): '%s...' -> '%s...'",
                t,
                max_tokens,
                len(text),
                len(corrected),
                text[:30],
                corrected[:50],
            )
            MemoryGuard.maybe_cleanup("post-correction")
            return {"correctedText": corrected or text, "changes": [],
                    "confidence": 0.9, "cached": False, "processingTimeMs": t}
        except Exception as e:
            logger.error(f"Correction failed: {e}")
            t = int((datetime.now() - t0).total_seconds() * 1000)
            MemoryGuard.maybe_cleanup("post-correction-error")
            return {"correctedText": text, "changes": [],
                    "confidence": 0.5, "cached": False, "processingTimeMs": t}

    @staticmethod
    def _normalize_vocabulary(vocabulary) -> list:
        if not vocabulary:
            return []
        if isinstance(vocabulary, str):
            raw_items = re.split(r"[,，、;；\n]+", vocabulary)
        elif isinstance(vocabulary, list):
            raw_items = []
            for item in vocabulary:
                if isinstance(item, str):
                    raw_items.append(item)
                elif isinstance(item, dict):
                    raw_items.append(str(item.get("term") or item.get("word") or item.get("text") or ""))
                else:
                    raw_items.append(str(item))
        else:
            raw_items = [str(vocabulary)]

        seen = set()
        result = []
        for item in raw_items:
            term = item.strip()
            if not term or term in seen:
                continue
            seen.add(term)
            result.append(term)
        return result[:200]

    @staticmethod
    def _enforce_vocabulary(text: str, vocabulary_items: list) -> str:
        if not text or not vocabulary_items:
            return text

        corrected = text
        for term in sorted(vocabulary_items, key=len, reverse=True):
            term = term.strip()
            if not term:
                continue
            corrected = re.sub(re.escape(term), term, corrected, flags=re.IGNORECASE)
            parts = [p for p in re.split(r"\s+", term) if p]
            if len(parts) < 2:
                continue
            corrected = TextCorrectionService._enforce_phrase_tokens(corrected, parts, term)
        return corrected

    @staticmethod
    def _enforce_phrase_tokens(text: str, parts: list, term: str) -> str:
        token_matches = list(re.finditer(r"[A-Za-z0-9]+", text))
        if len(token_matches) < len(parts):
            return text

        replacements = []
        window_size = len(parts)
        for start_index in range(0, len(token_matches) - window_size + 1):
            window = token_matches[start_index:start_index + window_size]
            if all(
                TextCorrectionService._token_close(match.group(0), expected)
                for match, expected in zip(window, parts)
            ):
                replacements.append((window[0].start(), window[-1].end(), term))

        if not replacements:
            return text

        result = text
        for start, end, replacement in reversed(replacements):
            result = result[:start] + replacement + result[end:]
        return result

    @staticmethod
    def _token_close(actual: str, expected: str) -> bool:
        actual_norm = actual.lower()
        expected_norm = expected.lower()
        if actual_norm == expected_norm:
            return True
        if len(expected_norm) <= 3:
            return False
        return TextCorrectionService._edit_distance_at_most_one(actual_norm, expected_norm)

    @staticmethod
    def _edit_distance_at_most_one(left: str, right: str) -> bool:
        if abs(len(left) - len(right)) > 1:
            return False
        i = 0
        j = 0
        edits = 0
        while i < len(left) and j < len(right):
            if left[i] == right[j]:
                i += 1
                j += 1
                continue
            edits += 1
            if edits > 1:
                return False
            if len(left) == len(right):
                i += 1
                j += 1
            elif len(left) < len(right):
                j += 1
            else:
                i += 1
        if i < len(left) or j < len(right):
            edits += 1
        return edits <= 1

    def _max_generation_tokens(self, text: str) -> int:
        """Scale output budget with input size so long dictations are not truncated."""
        input_tokens = 0
        try:
            input_tokens = len(self.tokenizer.encode(text, add_special_tokens=False))
        except Exception:
            input_tokens = len(text)

        requested = int(input_tokens * MLX_OUTPUT_TOKEN_RATIO) + 64
        return max(MLX_MIN_TOKENS, min(MLX_MAX_TOKENS, requested))

    def get_memory_usage(self) -> float:
        try:
            import psutil
            return psutil.Process(os.getpid()).memory_info().rss / 1024 / 1024
        except Exception:
            return 0.0

# ============================================================================
# ASR Service (SenseVoice via FunASR)
# ============================================================================

class ASRService:
    def __init__(self, model_dir: str = "./models/sensevoice"):
        self.model_dir = model_dir
        self.model = None
        self.is_loaded = False

    def load_model(self):
        try:
            t0 = datetime.now()
            logger.info(f"Loading SenseVoice from {self.model_dir}...")
            from funasr import AutoModel

            self.model = AutoModel(
                model=self.model_dir,
                disable_update=True,
                device="mps",  # Apple Silicon GPU
            )
            self.is_loaded = True
            elapsed = int((datetime.now() - t0).total_seconds() * 1000)
            logger.info(f"SenseVoice loaded in {elapsed}ms")
            return True
        except Exception as e:
            logger.error(f"Failed to load SenseVoice: {e}")
            self.is_loaded = False
            return False

    def transcribe(self, audio_path: str, language: str = "auto") -> Dict[str, Any]:
        if not self.is_loaded:
            raise RuntimeError("ASR model not loaded")

        try:
            t0 = datetime.now()

            lang_hint = "zh" if language in ("zh", "auto") else language

            # Load audio with soundfile (handles WAV natively, no ffmpeg needed)
            try:
                import soundfile as sf
                audio_data, sr = sf.read(audio_path)
                # Resample to 16kHz if different
                if sr != 16000:
                    import librosa
                    audio_data = librosa.resample(audio_data, orig_sr=sr, target_sr=16000)
                results = self.model.generate(input=audio_data, language=lang_hint)
            except Exception as e:
                logger.warning(f"soundfile load failed: {e}, trying FunASR direct")
                results = self.model.generate(input=audio_path, language=lang_hint)

            # Parse result
            raw_text = ""
            detected_lang = "zh"
            if results and len(results) > 0:
                full = results[0].get("text", "")
                raw_text = clean_sensevoice_text(full)
                # Detect language from tags
                if "<|en|>" in full:
                    detected_lang = "en"
                elif "<|zh|>" in full:
                    detected_lang = "zh"
                elif "<|ja|>" in full:
                    detected_lang = "ja"
                elif "<|ko|>" in full:
                    detected_lang = "ko"

            elapsed = int((datetime.now() - t0).total_seconds() * 1000)
            logger.info(f"ASR result ({elapsed}ms): [{detected_lang}] {raw_text[:80]}")

            MemoryGuard.maybe_cleanup("post-asr")
            return {
                "rawText": raw_text,
                "language": detected_lang,
                "confidence": 0.95,
                "processingTimeMs": elapsed,
            }
        except Exception as e:
            logger.error(f"ASR error: {e}", exc_info=True)
            MemoryGuard.maybe_cleanup("post-asr-error")
            raise

# ============================================================================
# FastAPI Application
# ============================================================================

@asynccontextmanager
async def lifespan(_app: FastAPI):
    await startup_event()
    try:
        yield
    finally:
        await shutdown_event()


app = FastAPI(
    title="Open Speech ASR - Legacy Local Inference Service",
    description="可选本地后端 — SenseVoice ASR + Gemma E4B 纠错",
    version="1.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "http://127.0.0.1:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def attach_backend_identity(request, call_next):
    response = await call_next(request)
    response.headers["X-Open-Speech-Session"] = BACKEND_SESSION_TOKEN
    response.headers["X-Open-Speech-PID"] = str(os.getpid())
    return response


# Determine base dir for model paths
_BASE_DIR = os.path.dirname(os.path.abspath(__file__))

correction_service = TextCorrectionService(
    model_dir=os.path.join(_BASE_DIR, "models", "gemma-e4b-q4"),
)
asr_service = ASRService(
    model_dir=os.path.join(_BASE_DIR, "models", "sensevoice")
)


async def startup_event():
    logger.info("Starting up MLX Voice Input service...")
    MemoryGuard.configure_mlx_limits()
    asyncio.create_task(MemoryGuard.monitor_loop())
    if LOCAL_LLM_ENABLED:
        correction_service.load_model()
    else:
        logger.info("Local Gemma correction model disabled; starting SenseVoice ASR only")
    if LOCAL_ASR_ENABLED:
        asr_service.load_model()
    else:
        logger.info("SenseVoice ASR disabled; running Gemma correction backend only")
    MemoryGuard.maybe_cleanup("startup", force=True)
    logger.info("Service startup complete")


async def shutdown_event():
    logger.info("Shutting down...")


@app.get("/health", response_model=HealthResponse)
async def health_check():
    memory = MemoryGuard.snapshot()
    asr_ready = (not LOCAL_ASR_ENABLED) or asr_service.is_loaded
    llm_ready = (not LOCAL_LLM_ENABLED) or correction_service.is_loaded
    return HealthResponse(
        status="healthy" if asr_ready and llm_ready else "degraded",
        processId=os.getpid(),
        sessionToken=BACKEND_SESSION_TOKEN,
        modelLoaded=correction_service.is_loaded,
        localLLMEnabled=LOCAL_LLM_ENABLED,
        asrLoaded=asr_service.is_loaded,
        memoryUsageMb=memory["memoryUsageMb"],
        memorySoftLimitMb=memory["memorySoftLimitMb"],
        memoryCleanupThresholdMb=memory["memoryCleanupThresholdMb"],
        memoryRestartThresholdMb=memory["memoryRestartThresholdMb"],
        needsMemoryCleanup=memory["needsMemoryCleanup"],
        needsBackendRestart=memory["needsBackendRestart"],
        mlxTrackedMemoryMb=memory["mlxTrackedMemoryMb"],
        mlxActiveMemoryMb=memory["mlxActiveMemoryMb"],
        mlxCacheMemoryMb=memory["mlxCacheMemoryMb"],
        mlxCacheLimitMb=memory["mlxCacheLimitMb"],
        mlxMemoryLimitMb=memory["mlxMemoryLimitMb"],
        mlxActiveOverSoftLimit=memory["mlxActiveOverSoftLimit"],
        lastMemoryCleanup=memory["lastMemoryCleanup"],
        timestamp=datetime.now().isoformat(),
    )


@app.post("/api/infer/correct", response_model=CorrectTextResponse)
async def correct_text(request: CorrectTextRequest):
    try:
        if not LOCAL_LLM_ENABLED:
            raise HTTPException(status_code=503, detail="Local LLM correction is disabled")
        result = correction_service.correct_text(
            text=request.text,
            context=request.context,
            vocabulary=request.vocabulary,
        )
        return CorrectTextResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"correct_text error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/asr/transcribe-upload", response_model=TranscribeResponse)
async def transcribe_upload(
    file: UploadFile = File(...),
    language: str = "auto",
    enableCorrection: bool = True,
):
    """转录音频 - 直接文件上传 (WebM/WAV/MP3等)"""
    try:
        if not LOCAL_ASR_ENABLED:
            raise HTTPException(status_code=503, detail="SenseVoice ASR is disabled in this backend mode")
        # Save uploaded file to temp
        suffix = _guess_suffix(file.filename or "")
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            content = await file.read()
            tmp.write(content)
            audio_path = tmp.name

        asr_result = asr_service.transcribe(audio_path=audio_path, language=language)

        # Clean up temp file
        try:
            os.unlink(audio_path)
        except Exception:
            pass

        corrected_text = None
        if enableCorrection and LOCAL_LLM_ENABLED and asr_result["rawText"]:
            cr = correction_service.correct_text(text=asr_result["rawText"])
            corrected_text = cr["correctedText"]

        return TranscribeResponse(
            rawText=asr_result["rawText"],
            correctedText=corrected_text,
            language=asr_result["language"],
            confidence=asr_result["confidence"],
            processingTimeMs=asr_result["processingTimeMs"],
            ttftMs=0,
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"transcribe_upload error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================================
# LocalBackendClient endpoints (isLocalMode)
# ============================================================================

@app.post("/asr")
async def local_asr(
    file: UploadFile = File(...),
):
    """Local mode ASR — same as transcribe-upload."""
    import tempfile
    try:
        if not LOCAL_ASR_ENABLED:
            raise HTTPException(status_code=503, detail="SenseVoice ASR is disabled in this backend mode")
        suffix = os.path.splitext(file.filename or ".wav")[1] or ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            content = await file.read()
            tmp.write(content)
            audio_path = tmp.name

        result = asr_service.transcribe(audio_path=audio_path, language="zh")
        try: os.unlink(audio_path)
        except: pass
        return {"text": result["rawText"]}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"/asr error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/polish")
async def local_polish(request: dict):
    """Local mode text polish — uses custom prompt if provided."""
    try:
        if not LOCAL_LLM_ENABLED:
            raise HTTPException(status_code=503, detail="Local LLM correction is disabled")
        text = request.get("text", "")
        custom_prompt = request.get("prompt", "")
        vocabulary = request.get("vocabulary")
        context = request.get("context")
        result = correction_service.correct_text(
            text=text,
            context=context,
            vocabulary=vocabulary,
            custom_prompt=custom_prompt,
        )
        return {"polished": result["correctedText"]}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"/polish error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================================
# OpenAI-compatible endpoints (for FreeFlow native app)
# ============================================================================

@app.post("/v1/audio/transcriptions")
async def openai_transcribe(
    file: UploadFile = File(...),
    model: str = "sensevoice",
    language: str = "auto",
    response_format: str = "verbose_json",
):
    """OpenAI-compatible transcription endpoint for FreeFlow."""
    try:
        if not LOCAL_ASR_ENABLED:
            raise HTTPException(status_code=503, detail="SenseVoice ASR is disabled in this backend mode")
        suffix = ".webm" if file.filename and file.filename.endswith(".webm") else ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            content = await file.read()
            tmp.write(content)
            audio_path = tmp.name

        result = asr_service.transcribe(audio_path=audio_path, language=language)

        # Clean up
        try:
            os.unlink(audio_path)
        except Exception:
            pass

        if response_format == "verbose_json":
            return {"text": result["rawText"], "language": result["language"],
                    "segments": [], "duration": 0}
        return {"text": result["rawText"]}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"OpenAI transcribe error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/v1/chat/completions")
async def openai_chat_completions(request: dict):
    """OpenAI-compatible chat completions for FreeFlow post-processing."""
    try:
        if not LOCAL_LLM_ENABLED:
            raise HTTPException(status_code=503, detail="Local LLM correction is disabled")
        messages = request.get("messages", [])
        model = request.get("model", "gemma4-e4b")

        # Extract raw transcription from FreeFlow's verbose formatting
        user_text = ""
        for msg in messages:
            if msg["role"] == "user":
                raw = msg.get("content", "")
                # Strip FreeFlow's verbose wrapper, keep only transcription
                import re
                m = re.search(r'RAW_TRANSCRIPTION:\s*"(.+?)"', raw, re.DOTALL)
                if m:
                    user_text = m.group(1).strip()
                else:
                    user_text = raw.strip()
                break

        if not user_text:
            return {"id": "local-001", "object": "chat.completion", "created": 0,
                    "model": model, "choices": [{"index": 0,
                    "message": {"role": "assistant", "content": ""},
                    "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}}

        # Use our correction service with the cleaned text only
        result = correction_service.correct_text(text=user_text, vocabulary=None)
        corrected = result["correctedText"]
        if not corrected or corrected.isspace():
            corrected = user_text if user_text else ""

        return {
            "id": "local-001",
            "object": "chat.completion",
            "created": int(datetime.now().timestamp()),
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": corrected},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Chat completion error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/metrics")
async def get_metrics():
    memory = MemoryGuard.snapshot()
    return {
        "processId": os.getpid(),
        "sessionToken": BACKEND_SESSION_TOKEN,
        "modelLoaded": correction_service.is_loaded,
        "localLLMEnabled": LOCAL_LLM_ENABLED,
        "asrLoaded": asr_service.is_loaded,
        "modelLoadTimeMs": correction_service.load_time_ms,
        **memory,
        "timestamp": datetime.now().isoformat(),
    }


@app.post("/api/memory/cleanup")
async def cleanup_memory(request: Optional[MemoryCleanupRequest] = Body(default=None)):
    reason = request.reason if request and request.reason else "manual-api"
    triggered = MemoryGuard.maybe_cleanup(
        reason,
        force=True,
        global_soft_limit_mb=request.globalSoftLimitMb if request else None,
        peer_tracked_memory_mb=request.peerMlxTrackedMemoryMb if request else 0.0,
        peer_memory_footprint_mb=request.peerMemoryFootprintMb if request else None,
    )
    last_cleanup = MemoryGuard.last_cleanup or {}
    return {
        "triggered": triggered,
        **MemoryGuard.snapshot(),
        "needsBackendRestart": bool(last_cleanup.get("restartRecommended", False)),
        "timestamp": datetime.now().isoformat(),
    }


def _guess_suffix(filename: str) -> str:
    if not filename:
        return ".webm"
    ext = os.path.splitext(filename)[1].lower()
    return ext if ext else ".webm"


# ============================================================================
# Main
# ============================================================================

if __name__ == "__main__":
    port = int(os.getenv("INFERENCE_PORT", 8001))
    host = os.getenv("INFERENCE_HOST", "127.0.0.1")
    logger.info(f"Starting inference server on {host}:{port}")
    uvicorn.run(app, host=host, port=port, log_level="info")
