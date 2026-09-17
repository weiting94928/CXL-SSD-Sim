# CXL-SSD-Sim 實作分析與初步執行驗證

六頁 meeting 內容與講稿，建議 12–15 分鐘。整理日期：2026-09-17。

證據範圍：目前工作目錄 HEAD 為 `b28e32a`；程式碼分析是目前 source 的靜態檢查。8/21 實驗依 `runs/o3-full-20260821/` 的既有輸出整理，沒有重新執行實驗，也未驗證當時 executable 與目前 source 完全一致。

## 第 1 頁｜本次目標：從論文架構追到實際執行

### 投影片內容

- 上次：介紹 CXL-SSD 論文的設計與效能評估。
- 本次：追蹤開源實作，確認系統如何建立、請求如何處理、延遲如何組成。
- 三個問題：
  1. Python 設定如何成為可執行的模擬系統？
  2. CPU 的讀取如何進入 CxlMemory 與 SimpleSSD？
  3. 8/21 的長時間實驗完成哪些子測試？還缺哪些驗證？
- 本次成果：程式碼路徑分析＋既有子測試輸出；完整 benchmark 尚未完成。

### 建議講稿

「上次報告主要是論文設計，這次我開始檢查開源實作。我從 full-system 啟動入口往下追到 CXL-SSD 讀取函式，並整理 8/21 長時間執行留下的結果。這次會區分程式碼已確認的行為、實際執行輸出，以及還需要小實驗驗證的問題。」

### 呈現方式

只放三個研究問題與一句成果範圍。不要重講整篇論文，也不要列出所有讀過的檔案。

## 第 2 頁｜系統建立與模擬啟動：Python 到 C++

### 投影片內容

```text
Host：執行 gem5、保存設定與輸出
  fs.py → 建立 CPU／cache／bus／CxlMemory 的 Python 設定
      ↓ Simulation.run()
  m5.instantiate() → 建立 C++ 物件、連接 ports、初始化／恢復狀態
      ↓ m5.simulate()
  doSimLoop() → serviceOne() → event->process()
      ↓
Guest：模擬 CPU 執行 Linux 與 benchmark
```

- `fs.py` 決定硬體組態；`Simulation.run()` 管理執行流程。
- `instantiate()` 將模型與接線實體化；`simulate()` 推進模擬。
- 模擬時間由事件推進，Guest 經過時間與 Host 等待時間不同。

### 建議講稿

「我一開始先釐清 Host 與 Guest：gem5 在真實電腦上執行，Linux 和 benchmark 則在模擬電腦裡執行。fs.py 建立設定，instantiate 建立對應 C++ 物件與連線，simulate 才進入事件迴圈。每次取出下一個事件，把模擬時間更新到事件時間，再執行事件，所以真實跑很久，不代表 Guest 也經過同樣長的時間。」

### 程式碼證據／備用說明

- [Simulation.py:677](/home/weiting/CXL-SSD-Sim/configs/common/Simulation.py:677)：`m5.instantiate(checkpoint_dir)`。
- [simulate.py:122](/home/weiting/CXL-SSD-Sim/src/python/m5/simulate.py:122)：`createCCObject()`、`connectPorts()`。
- [simulate.cc:301](/home/weiting/CXL-SSD-Sim/src/sim/simulate.cc:301)：`doSimLoop()` 反覆呼叫 `serviceOne()`。
- [eventq.cc:198](/home/weiting/CXL-SSD-Sim/src/sim/eventq.cc:198)：移出事件後，對未取消事件執行以下邏輯：

```cpp
setCurTick(event->when());
event->process();
```

老師追問 event loop 時再顯示這兩行，不需要主動逐行講所有初始化選項。

## 第 3 頁｜一次讀取：接線與資料／延遲的分工

### 投影片內容

```text
CPU／cache → MemBus → Bridge → IOBus → CxlMemory.pio
                                              ↓
                                     CxlMemory::read(pkt)
                                     ├─ access(pkt)：處理資料
                                     ├─ resolve_cxl_mem()：CXL 延遲
                                     └─ ssdRead()：裝置快取／SSD 延遲
```

SSD 分支核心節錄（省略記錄與條件編譯）：

```cpp
access(pkt);
Tick cxl_latency = resolve_cxl_mem(pkt);
Tick storage_latency = ssdRead(pkt);
return cxl_latency + storage_latency;
```

- `.pio` 是裝置接收 CPU 存取請求的接口。
- `access()` 從 Host 映射的 `CxlSSD.img` 讀寫資料。
- `ssdRead()` 先查外層快取，miss 路徑再呼叫 SimpleSSD HIL。

### 建議講稿

「我沿著 Python 接線確認 CxlMemory 掛在 IOBus 上，再追到 C++ 的 read 函式。這裡一個重要設計是資料與時間分開處理：access 提供資料，另外兩個函式計算延遲。外層 cache hit 會提早返回；miss 才進入 HIL。進入 HIL 不代表一定執行到 NAND，後端還有請求切分和快取邏輯。」

### 程式碼證據／備用說明

- [FSConfig.py:462](/home/weiting/CXL-SSD-Sim/configs/common/FSConfig.py:462)：建立 MemBus、IOBus 與 Bridge 並接線。
- [SouthBridge.py:101](/home/weiting/CXL-SSD-Sim/src/dev/x86/SouthBridge.py:101)：`self.cxlmemory.pio = bus.mem_side_ports`。
- [cxl_memory.cc:230](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:230)：`CxlMemory::read()`。
- [cxl_memory.cc:370](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:370)：一般讀／寫的資料處理。
- [cxl_memory.cc:419](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:419)：外層快取 hit 提早返回；455 行呼叫 `pHIL->read(request)`。

CPU cache、CxlMemory 外層 cache、SimpleSSD ICL cache 是不同層。不是所有 CPU load 都會到達裝置。

## 第 4 頁｜程式碼發現：延遲模型與請求粒度需分別驗證

### 投影片內容

**已確認：裝置的 CXL 延遲由固定參數提供。**

```cpp
// resolve_cxl_mem() 的回傳值
return cxl_mem_latency_;
```

- 目前 Python 預設值為 25 ns；不包含整條路徑的所有延遲。
- 這個函式的延遲抽象，不能單獨證明完整協定時序已被建模。

**待動態驗證：小 Packet 轉成 SSD 頁面數時是否為零？**

```cpp
#define CXL_SSD_PAGE_LEFT_BITS (10)
#define CXL_SSD_PAGE_SIZE (1LL << CXL_SSD_PAGE_LEFT_BITS)
request.range.nlp = pkt->getSize() / logical_page_size_;
```

若到達此處的 Packet 為 64 bytes：`64 / 1024 = 0`（整數除法）。

- 已知：巨集算出 1 KiB，旁邊註解卻寫 4K。
- 待確認：實際 Packet 大小、`nlp`，以及 ICL／FTL 是否處理該筆讀取。

### 建議講稿

「目前我確認 resolve_cxl_mem 回傳固定延遲參數；這是在描述模型粒度，還不是對整體準確性的結論。另外，外層頁面大小目前算出是 1 KiB，但 Packet 長度是直接用整數除法換成頁面數。如果實際收到 64-byte Packet，就可能得到零頁。下一步要用 trace 看實際是否發生，以及後端如何處理，不能先把初步效能差異都歸因於這個問題。」

### 程式碼證據／備用說明

- [CxlMemory.py:10](/home/weiting/CXL-SSD-Sim/src/dev/storage/CxlMemory.py:10)：`latency=50ns`、`cxl_mem_latency=25ns`。
- [cxl_memory.cc:298](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:298)：`resolve_cxl_mem()`。
- [cxl_memory.hh:24](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.hh:24)：頁面常數；411 行初始化 `logical_page_size_`。
- [cxl_memory.cc:450](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:450)：頁面數計算。
- [icl.cc:75](/home/weiting/CXL-SSD-Sim/src/dev/storage/simplessd/icl/icl.cc:75)：ICL 以 `req.range.nlp` 控制逐頁處理迴圈。需確認傳入值，才可判斷是否跳過這段迴圈。

本頁是目前 source 的檢查結果；沒有證據把這個疑點直接判定為 8/21 長時間執行的原因。

## 第 5 頁｜8/21 長時間模擬：已有子測試結果，整套未完成

### 投影片內容

來源：`runs/o3-full-20260821/`。

設定摘要：Guest RAM 512 MiB、CXL BAR 4 GiB、L1I／L1D 各 32 KiB、L2 512 KiB、cache line 64 B。Guest 輸出標示 X86O3CPU；保存的初始化設定包含 Atomic CPU 與待切換 O3 CPU。

兩段 STREAM 都輸出 `Solution Validates` 與各自的 finish 標記。每個 array 為 1,000,000 個 8-byte 元素，三個 array 合計約 22.9 MiB，每個 kernel 執行 10 次。

| STREAM 項目 | `stream_dram_m0` 標記的測試 | `stream_cxl_m1` 標記的測試 |
|---|---:|---:|
| Copy | 1839.1 MB/s | 353.5 MB/s |
| Scale | 1836.3 MB/s | 345.7 MB/s |
| Add | 2745.3 MB/s | 529.5 MB/s |
| Triad | 2746.7 MB/s | 606.3 MB/s |

```text
STREAM 兩組完成 → membench 兩組完成 → pool 建立
→ START PREFILL → ^C → 回到 Guest shell
```

頁尾註記：單次既有執行的程式輸出；整套未完成、`stats.txt` 為空，尚未完成重複實驗與 CXL 後端 trace 驗證。

### 建議講稿

「8/21 那次不是完全沒有結果。完整 Guest log 顯示 DRAM 和 CXL 標記的兩組 STREAM 都完成，算出的 array 也通過驗證。這裡的頻寬是 benchmark 在 Guest 內量到的數字，不是我的電腦跑 gem5 的速度。後續兩組 membench 也有完成標記，接著建立 pool、進入 prefill，最後 log 留下 Ctrl+C 和 Guest shell，因此整套沒有完成。這些數字目前作為初步輸出，我還不把它當成論文結果重現成功。」

### 證據與限制（留在講稿或備用頁）

- [Guest log:8](/home/weiting/CXL-SSD-Sim/runs/o3-full-20260821/system.pc.com_1.device:8)：程式印出的 CPU／記憶體設定標籤；標籤本身不能取代 runtime 設定證據。
- [Guest log:32](/home/weiting/CXL-SSD-Sim/runs/o3-full-20260821/system.pc.com_1.device:32)：第一組 STREAM 數據；38 行資料驗證、40 行 finish。
- [Guest log:63](/home/weiting/CXL-SSD-Sim/runs/o3-full-20260821/system.pc.com_1.device:63)：第二組 STREAM 數據；69 行資料驗證、71 行 finish。
- [Guest log:72](/home/weiting/CXL-SSD-Sim/runs/o3-full-20260821/system.pc.com_1.device:72)：兩組 membench 印出平均 7 ns／10 ns。只作已輸出結果，不解讀為裸 DRAM／NAND 裝置延遲。需先確認量測方法、cache 與路徑。
- membench 的 finish 標記寫 5MB，但內文 `Buffer Size` 是 8 MiB；因此主投影片不把它當作已確認的 5 MB 測試。
- [Guest log:91](/home/weiting/CXL-SSD-Sim/runs/o3-full-20260821/system.pc.com_1.device:91)：`/dev/cxl_mem0`、pool 建立、`START PREFILL`、`^C`、Guest prompt。
- [config.ini:99](/home/weiting/CXL-SSD-Sim/runs/o3-full-20260821/config.ini:99) 是初始 Atomic CPU；[config.ini:1772](/home/weiting/CXL-SSD-Sim/runs/o3-full-20260821/config.ini:1772) 是初始 `switched_out=true` 的 O3。`config.ini` 在啟動時輸出，不能把 `mem_mode=atomic` 直接解讀為整場都在 atomic 模式。該目錄沒有 Host log，未取得那次 runtime 切換訊息。
- 資料驗證通過表示 STREAM 算出的資料通過其檢查，不表示所有請求都抵達 NAND，也不表示時間模型已校準。
- 目前 `stats.txt` 是 0 bytes，沒有完整 gem5 統計；不能單憑它判定當時卡死。
- 設定檔修改時間為 8/21、Guest log 最後修改時間為 8/24。這僅為檔案時間，不能拿來宣稱連續執行約三天或精確執行時長。
- `^C` 與 Guest shell 表示 Guest 前景執行已被中斷；不能據此宣稱 gem5 程序也正常結束。
- 沒有 `FULL BENCHMARK END` 標記。最大 workload 名稱、實際預填規模與進度，仍需回查 Guest 的 `benchmark.sh` 和呼叫參數。
- 8/16 的 `runs/o3-full/stats.txt` 有 82,011 inst/s，但屬於另一場執行，不能當成 8/21 的速度或用來精確估算它的完成時間。

## 第 6 頁｜下一步：先驗證一筆請求，再擴大效能實驗

### 投影片內容

1. **固定實驗條件**：記錄 commit、執行檔、啟動命令、Guest 腳本與 workload 參數；保存 Host／Guest logs。
2. **完成小型路徑驗證**：讓少量存取確實抵達 CxlMemory，記錄地址、Packet 大小、外層 cache 狀態、`nlp` 與回傳延遲。
3. **確認後端處理**：追 HIL／ICL／FTL 呼叫；檢查小 Packet 是否得到零頁請求。
4. **分段跑效能測試**：先單獨完成 STREAM；較大 workload 從小規模 prefill 開始，分階段保存統計並量測 Host 耗時。

預期交付：一份可解釋的 request trace、一個完整結束的小型測試、一份分階段執行成本紀錄。

### 建議講稿

「下一步我先確定小實驗真的走到裝置，再確認頁面數和延遲的計算。之後把整套 benchmark 拆開，讓每個子測試都能正常結束並保存統計，再逐步增加 prefill 規模。這樣下一次可以用實際 trace 回答程式碼疑點，也可以用量到的執行成本評估大實驗需要的時間。」

### 實驗設計提醒

- 重複讀同一地址可能只命中 CPU cache；必須在 CxlMemory 入口確認請求是否到達。
- TimingSimpleCPU 可先用於功能／路徑驗證，但它的效能數字不能直接當 O3 結果。
- 縮小 workload 會改變 cache hit 行為；小實驗通過不等於原始規模結果已重現。
- Debug trace 本身有成本：小型診斷開 trace，正式計時需控制記錄開銷。
- 本文件僅整理報告與後續計畫，以上新實驗尚未執行。

## 報告問答備忘（不計入六頁）

**為什麼完整測試沒跑完，仍然有值得報告的內容？**

程式碼分析回答實作如何運作；子測試輸出證明已完成部分 workload。完整重現需要額外完成大 workload、記錄統計並核對論文條件。本次明確限定前兩者。

**為什麼會這麼慢？**

詳細 CPU／記憶體事件模擬具有 Host 運算成本，但目前無法由這份 log 定位 8/21 的特定瓶頸。下一步記錄每階段 Host 耗時、模擬進度、指令數和 workload 參數，區分正常前進、昂貴初始化和可能停滯。

**STREAM 的 CXL 頻寬比較低，代表原因就是 NAND 嗎？**

目前不能這樣歸因。它是該程式、該組態下的端到端量測；還受 CPU cache、裝置 cache、地址映射及後端模型影響。需要 trace 或控制變因實驗。

**prefill 是什麼？**

通常指正式操作測試前先填入資料、建立初始資料集的階段。這份 log 證明出現該標記，但尚未確認那個程式的具體資料量、操作次數和完成條件。

**Python 接線和 C++ 執行有什麼關係？**

Python 描述物件與 ports 連線；instantiate 建立 C++ 物件與連線。simulate 進入 event loop，處理硬體模型排入的事件。

**之前 smoke passed 能證明什麼？**

先前紀錄描述的是恢復 Guest、注入腳本與查看 benchmark 檔案的流程。現有 smoke.sh 在 ls 後直接印 PASSED，沒有對所有檢查失敗設置嚴格中止；單看字樣更不能當作完整驗證。它沒有測完 CXL 讀寫、沒有完成整套 benchmark。

**目前 source 發現的問題一定存在於 8/21 那個 binary 嗎？**

尚未建立完整版本對應，因此把目前 source 分析與歷史輸出分開陳述。後續執行需保存版本與 binary 資訊，才能把 trace 和原始碼一一對應。
