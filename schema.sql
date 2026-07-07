-- ============================================================
-- Investment OS — Supabase Schema
-- 貼到 Supabase SQL Editor 執行一次即可
-- ============================================================

-- 啟用 UUID 擴充功能
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── 持倉表 ──────────────────────────────────────────────────
-- 每一筆代表你「目前持有」某支股票的狀態
CREATE TABLE IF NOT EXISTS holdings (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol        TEXT    NOT NULL,           -- 股票代號，例如 "NVDA"
  shares        NUMERIC NOT NULL,           -- 持股數量（= 起始基準 + 交易回放，由後端重算）
  avg_cost      NUMERIC NOT NULL,           -- 平均成本（同上，重算結果）
  opening_shares    NUMERIC,                -- 起始基準股數（交易記錄之前的部位）
  opening_avg_cost  NUMERIC,                -- 起始基準成本
  cost_basis_date   DATE DEFAULT CURRENT_DATE,  -- 成本基準日：拆股調整基準（此日之後拆股才調整股數/成本），新列預設今天
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- 既有資料庫補欄位用（新建可忽略）：補上 cost_basis_date，舊資料回填為建立日
-- ALTER TABLE holdings ADD COLUMN IF NOT EXISTS cost_basis_date DATE DEFAULT CURRENT_DATE;
-- UPDATE holdings SET cost_basis_date = created_at::date WHERE cost_basis_date IS NULL;

-- ── 交易記錄表 ───────────────────────────────────────────────
-- 每一筆買賣都記下來，是計算損益的原始資料
CREATE TABLE IF NOT EXISTS transactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol           TEXT    NOT NULL,
  transaction_type TEXT    NOT NULL CHECK (transaction_type IN ('BUY','SELL')),
  shares           NUMERIC NOT NULL,
  price            NUMERIC NOT NULL,        -- 成交價（美元）
  total_amount     NUMERIC NOT NULL,        -- shares × price
  transaction_date DATE    NOT NULL,
  notes            TEXT,
  realized_pnl     NUMERIC,                 -- 已實現損益（僅 SELL 有值 =(賣價-均成本)×股數 − 費用）
  fee              NUMERIC DEFAULT 0,       -- 手續費＋證交稅（BUY 計入成本、SELL 從已實現損益扣除）
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- 既有資料庫補欄位用（新建可忽略，已含在上面 CREATE）：
-- ALTER TABLE transactions ADD COLUMN IF NOT EXISTS realized_pnl NUMERIC;
-- ALTER TABLE transactions ADD COLUMN IF NOT EXISTS fee NUMERIC DEFAULT 0;

-- ── 投資現金事件表（2026-06-27 現金管理新增）─────────────────────
-- 記入金 / 出金 / 換匯三種事件，現金餘額由「這張表 ＋ 交易買賣」自動推算，不手存餘額。
--   入金 DEPOSIT / 出金 WITHDRAW → currency + amount（正數）
--   換匯 CONVERT → from_currency/from_amount（換出）+ to_currency/to_amount（換入），rate=台幣額/美金額
CREATE TABLE IF NOT EXISTS cash_flows (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  flow_type     TEXT NOT NULL CHECK (flow_type IN ('DEPOSIT','WITHDRAW','CONVERT','DIVIDEND')),
  symbol        TEXT,                                     -- DIVIDEND：股息來源代號（也用來去重「已入帳」）
  currency      TEXT CHECK (currency IN ('TWD','USD')),  -- 入金/出金/股息用
  amount        NUMERIC,                                  -- 入金/出金/股息金額（正數）
  from_currency TEXT,                                     -- 換匯：換出幣別
  from_amount   NUMERIC,                                  -- 換匯：換出金額
  to_currency   TEXT,                                     -- 換匯：換入幣別
  to_amount     NUMERIC,                                  -- 換匯：換入金額
  rate          NUMERIC,                                  -- 匯率（TWD per USD）：換匯實際成交、或USD入金折本金用
  flow_date     DATE NOT NULL,
  notes         TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE cash_flows ENABLE ROW LEVEL SECURITY;
-- 遷移（既有 DB 需手動跑；CREATE TABLE IF NOT EXISTS 對已存在的表是 no-op）：股息實收 DIVIDEND
--   ALTER TABLE cash_flows DROP CONSTRAINT IF EXISTS cash_flows_flow_type_check;
--   ALTER TABLE cash_flows ADD  CONSTRAINT cash_flows_flow_type_check CHECK (flow_type IN ('DEPOSIT','WITHDRAW','CONVERT','DIVIDEND'));
--   ALTER TABLE cash_flows ADD COLUMN IF NOT EXISTS symbol TEXT;
--   CREATE UNIQUE INDEX IF NOT EXISTS uniq_dividend_symbol_date ON cash_flows(symbol, flow_date) WHERE flow_type = 'DIVIDEND';

-- ── 觀察清單表 ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS watchlist (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol       TEXT    NOT NULL UNIQUE,
  target_price NUMERIC,                     -- 你設定的目標價
  notes        TEXT,
  want_buy     BOOLEAN DEFAULT false,       -- 「想買/納入藍圖」：true＝進再平衡目標卡＋晨報入場提醒
  added_at     TIMESTAMPTZ DEFAULT NOW()
);
-- 遷移（既有 DB 需手動跑；CREATE TABLE IF NOT EXISTS 對已存在的表是 no-op）：想買旗標
--   ALTER TABLE watchlist ADD COLUMN IF NOT EXISTS want_buy BOOLEAN DEFAULT false;

-- ── 股價快取表 ───────────────────────────────────────────────
-- 快取 yfinance 抓回來的資料，避免頻繁打外部 API
CREATE TABLE IF NOT EXISTS stock_price_cache (
  symbol              TEXT PRIMARY KEY,
  name                TEXT,
  sector              TEXT,
  price               NUMERIC,
  change_pct          NUMERIC,              -- 今日漲跌幅 %
  pe_ratio            NUMERIC,
  forward_pe          NUMERIC,              -- 估值燈號 2.0：forward P/E
  earnings_growth     NUMERIC,              -- 估值燈號 2.0：盈餘成長率 %（PEG 用）
  roe                 NUMERIC,              -- 以百分比儲存，例如 25.4
  dividend_yield      NUMERIC,              -- 以百分比儲存，例如 1.38
  market_cap          BIGINT,               -- 以美元儲存
  beta                NUMERIC,
  fifty_two_week_high NUMERIC,
  fifty_two_week_low  NUMERIC,
  eps_growth          NUMERIC,              -- 年度 EPS 成長率 %
  target_price        NUMERIC,              -- 分析師目標價（中位數）
  cached_at           TIMESTAMPTZ DEFAULT NOW()
);

-- ── 自動更新 updated_at ──────────────────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = '';   -- 2026-06-17 修 Security Advisor 的 search_path mutable 警告

CREATE TRIGGER holdings_updated_at
  BEFORE UPDATE ON holdings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── RLS（Row Level Security）：2026-06-17 改為開啟 ───────────
-- 後端走 service_role key 會自動繞過 RLS，不加 anon policy 即等於
-- 對 anon/public 全鎖（deny-all）。修掉 Supabase Security Advisor 的
-- "RLS Disabled in Public" ERROR。日後新增表務必比照開啟。
ALTER TABLE holdings            ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE watchlist           ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_price_cache   ENABLE ROW LEVEL SECURITY;

-- ── 每日 NAV 快照表（2026-06-19 晨報投資版新增）─────────────────
-- 由晨報排程（台灣 07:30 = 美股收盤後）每天寫一筆，做真正的權益曲線。
-- snapshot_date 用「美股交易日」(America/New_York 當下日期)，每日一筆 upsert。
CREATE TABLE IF NOT EXISTS nav_snapshot (
  snapshot_date  DATE PRIMARY KEY,          -- 美股交易日
  total_value    NUMERIC NOT NULL,          -- 全組合市值（美股+台股，已折算的話另計，此處原幣加總）
  us_value       NUMERIC,
  tw_value       NUMERIC,
  unrealized_pnl NUMERIC,
  created_at     TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE nav_snapshot ENABLE ROW LEVEL SECURITY;

-- ── 應用設定表（2026-06-19 新增）────────────────────────────────
-- 通用 key→JSONB 設定。目前用途：把再平衡「目標配置」從前端 localStorage
-- 搬到伺服器端，讓晨報排程算得到偏移。
--   key = target_alloc_us / target_alloc_tw，value = { "Technology": 40, "ETF": 30, ... }
CREATE TABLE IF NOT EXISTS app_settings (
  key        TEXT PRIMARY KEY,
  value      JSONB NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

-- ── 持倉體質月度快照表（2026-06-26 體質監控新增）─────────────────
-- 每月一筆/每支「個股」持倉，記基本面快照，用來跟上月比、抓體質惡化。
-- ETF 不記（一籃子無單一公司體質）。
CREATE TABLE IF NOT EXISTS fundamental_snapshot (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol              TEXT NOT NULL,
  snapshot_date       DATE NOT NULL,            -- 快照日（每月一次）
  roe                 NUMERIC,                  -- 股東權益報酬率 %
  revenue_growth      NUMERIC,                  -- 營收成長率 %
  net_margin          NUMERIC,                  -- 淨利率 %
  debt_to_equity      NUMERIC,                  -- 負債/權益（比值，如 1.73）
  recommendation_mean NUMERIC,                  -- 分析師評等均值（1強買..5賣）
  target_price        NUMERIC,                  -- 分析師目標價（中位）
  forward_pe          NUMERIC,                  -- 前瞻本益比
  price               NUMERIC,                  -- 快照當下股價
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(symbol, snapshot_date)
);
ALTER TABLE fundamental_snapshot ENABLE ROW LEVEL SECURITY;

-- ── 訊號回饋計分板（2026-06-27 B 新增）─────────────────────────
-- 每週把篩選器「AI Score ≥80（買入）」的標的記一筆，含當下價 + 同期大盤價，
-- 之後對答案算「後續報酬」與「超額報酬（扣同期大盤）」，驗證選股評分準不準。
CREATE TABLE IF NOT EXISTS signal_log (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol                    TEXT NOT NULL,
  name                      TEXT,
  signal_date               DATE NOT NULL,          -- 訊號發出日（每週一次）
  ai_score                  INTEGER,
  market                    TEXT,                   -- 'us' | 'tw'
  price_at_signal           NUMERIC,                -- 訊號當下股價
  benchmark_symbol          TEXT,                   -- 'VOO'（美股）| '0050.TW'（台股）
  benchmark_price_at_signal NUMERIC,                -- 同期大盤當下價
  created_at                TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(symbol, signal_date)
);
ALTER TABLE signal_log ENABLE ROW LEVEL SECURITY;

-- ── BOS 護城河/風險分析（2026-07-06 新版評分持久化）────────────────
-- 存「慢速、1–3 年才重跑一次」的 Claude 結果（護城河/風險/分類）＋使用者覆寫。
-- 財報 E.D.F.R.I 與估價買進價是純數據、每次即時重算，不存這裡。
-- 用途：重開/換 session 不用重付 Claude 費用；新財報出來時比對 financial_period 提醒重算。
CREATE TABLE IF NOT EXISTS bos_analysis (
  symbol                  TEXT PRIMARY KEY,       -- 解析後代號（.TW→.TWO 已處理）
  name                    TEXT,
  market                  TEXT,                   -- 'us' | 'tw'
  classification          TEXT,                   -- Claude 建議類型：資產股/股息股/成長股
  is_financial            BOOLEAN DEFAULT false,  -- 金融業（F 自由現金流免評用）
  moat_json               JSONB,                  -- 5 種護城河 [{type,hit,reason}]
  confidence_note         TEXT,                   -- Claude「無明確護城河但看好」的理由
  net_margin_json         JSONB,                  -- {score, reason}
  risk_json               JSONB,                  -- 3 項風險 [{code,name,deduct,reason}]
  summary                 TEXT,                   -- 一句話總結
  financial_period        TEXT,                   -- 分析當下最新財報年（如 "2025"）
  analyzed_at             TIMESTAMPTZ DEFAULT NOW(),
  -- 使用者覆寫（Claude 出草稿、使用者拍板）──────────────────────
  classification_override TEXT,                   -- 覆寫分類（優先於 classification）
  primary_method_override TEXT,                   -- 覆寫主用估價法：asset/dividend/growth_pe/peg
  moat_confidence_bonus   BOOLEAN DEFAULT false   -- 核可「對公司有自信 +1」（命中 0 種時）
);
ALTER TABLE bos_analysis ENABLE ROW LEVEL SECURITY;

-- ── DGM 股息成長 · 軸三 AI 定性分析（Claude Opus 慢速結果持久化）─────────────
-- 比照 bos_analysis：股息安全性/護城河/定價權的 Claude 判斷存這裡，1–3 年才重評一次；
-- 重開/換 session 直接讀這張、不重付費（只有「護城河重評」才重跑 Opus）。
-- RLS 開、不加 anon policy → 只有後端 service_role 能存取（與 bos_analysis 一致）。
CREATE TABLE IF NOT EXISTS dgm_analysis (
  symbol            TEXT PRIMARY KEY,       -- 解析後代號（.TW→.TWO 已處理）
  name              TEXT,
  market            TEXT,                   -- 'us' | 'tw'
  cut_risk          TEXT,                   -- 砍息風險：低/中/高（=高 時建議降級為「繼續觀察」）
  cut_risk_reason   TEXT,
  moat_strength     TEXT,                   -- 護城河：強/中/弱
  moat_reason       TEXT,
  pricing_power     TEXT,                   -- 定價權：強/中/弱
  pricing_reason    TEXT,
  summary           TEXT,                   -- 一句話總評
  financial_period  TEXT,                   -- 分析當下最新財報年（如 "2025"）
  analyzed_at       TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE dgm_analysis ENABLE ROW LEVEL SECURITY;

-- ── 範例初始資料（可選）────────────────────────────────────────
-- 貼入後你可以在 Dashboard 立刻看到資料，確認系統正常運作
INSERT INTO holdings (symbol, shares, avg_cost) VALUES
  ('NVDA', 15, 620.00),
  ('AAPL', 40, 165.00),
  ('MSFT', 20, 370.00),
  ('VOO',  30, 430.00),
  ('JPM',  25, 178.00)
ON CONFLICT DO NOTHING;

INSERT INTO watchlist (symbol, target_price, notes) VALUES
  ('AMD',  220.00, 'AI GPU 競爭者，關注 MI300 出貨量'),
  ('PLTR', 40.00,  'AI 政府合約持續成長'),
  ('CRWD', 430.00, '資安龍頭，訂閱制收入穩定'),
  ('AVGO', 1800.00,'AI 網路晶片需求強')
ON CONFLICT DO NOTHING;
