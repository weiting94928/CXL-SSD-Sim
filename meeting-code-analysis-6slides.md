# CXL-SSD-Sim 實作分析與初步執行驗證

六頁 meeting 內容與完整口頭講稿，建議 15–18 分鐘。整理日期：2026-09-17。

使用方式：投影片只放「投影片內容」；「完整講稿」放在講者備忘，分段練習，不必把長段文字貼上投影片。第四頁是本次重點，可分三次顯示；程式碼展開與問答留作備用。建議時間：第 1 頁 1–2 分鐘、第 2 頁 2 分鐘、第 3 頁 2–3 分鐘、第 4 頁 4–5 分鐘、第 5 頁 3 分鐘、第 6 頁 2 分鐘。

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

### 完整講稿

上次我介紹的是論文提出的 CXL-SSD 架構，以及作者怎麼評估它的效能。這次我把重點往實作移動，想確認論文裡的元件，在開源程式中分別由誰負責，以及一次讀取真正會經過哪些函式。

這份專案建立在 gem5 和 SimpleSSD 上。因為程式很多，我採用的閱讀方式是先找 full-system 的啟動入口，確認模擬電腦如何建立，再沿著一筆請求往下追到 CxlMemory 和 SSD 後端。這樣每讀一個檔案，都能回答它在整條路徑中負責什麼。

這次主要回答三個問題。第一，Python 設定怎麼變成實際執行的 C++ 模型。第二，CPU 存取如何到達 CXL-SSD，資料與延遲又如何處理。第三，8/21 那次長時間模擬到底跑到哪裡，留下哪些可以使用的結果。

目前我已經整理出核心呼叫路徑，也找到了固定延遲、寫回 TODO，以及請求粒度換算這幾個需要注意的地方。另外，8/21 的 log 顯示部分子測試已完成，雖然整套 benchmark 尚未結束。接下來我會分別說明哪些是程式碼已確認的事實、哪些是執行輸出，以及哪些還是需要驗證的推論。

接著先從啟動流程開始，因為這能說明後面那些硬體模型是怎麼被執行起來的。

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

### 完整講稿

這裡先區分兩個執行環境。Host 是我實際使用的電腦，負責執行 gem5，保存設定和結果。Guest 是 gem5 裡模擬出來的 x86 電腦，Linux kernel 和 benchmark 在這個模擬環境中執行。所以 Host 跑了多久，跟 benchmark 在 Guest 裡量到多久，不能直接混在一起。

啟動時，fs.py 先讀取命令列參數，例如 CPU 類型、記憶體容量和 cache 設定，再建立對應的 Python 模擬物件。CxlMemory 是透過 PC 平台裡的 SouthBridge 建立，並接到 IOBus。這時主要是在描述整台電腦的組態與連線。

接下來 Simulation.run 管理執行流程，其中 m5.instantiate 會遍歷物件樹，呼叫 createCCObject 建立對應 C++ 物件，再透過 connectPorts 把接口連起來。然後初始化狀態；如果指定 checkpoint，就恢復先前保存的模擬狀態。

真正推進模擬的是 m5.simulate。它會進入 C++ 的 doSimLoop，反覆呼叫 serviceOne，處理佇列裡下一個事件。核心就是投影片上的兩行：先把模擬時間更新到事件發生的時間，再呼叫 event->process 執行事件。事件執行時，也可能安排下一個事件。

例如 Bridge 要延後轉送 Packet，就安排未來的轉送事件。gem5 不需要在 Host 上真的等待那幾個奈秒，而是計算事件與更新狀態。這也解釋為什麼 Guest 內很短的一段程式，Host 可能要花很久才能模擬完；不過要定位 8/21 那次特別慢的原因，仍然需要進度和耗時紀錄。

知道系統如何開始執行後，下一頁就追一筆存取，看看它如何走到 CXL-SSD。

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

### 完整講稿

這張圖描述的是一筆需要往裝置送出的存取。CPU 發出存取後，如果已在 CPU cache 得到資料，就不需要一路走到 CxlMemory。因此這裡不能把每一個 load 都理解成一次 SSD 讀取。

當請求需要往下送，而且目標地址屬於 CXL-SSD 裝置範圍時，會經過 MemBus、Bridge 和 IOBus。Bus 依照地址決定出口；Bridge 連接兩邊的匯流排，並加入轉送延遲。CxlMemory.pio 是裝置接收這些請求的接口，就像裝置的收件窗口。Python 裡的接線是 self.cxlmemory.pio 等於 bus.mem_side_ports，之後讀取請求會被分派到 CxlMemory::read。

read 函式的核心就是這四行。access 負責資料內容，一般讀寫會存取 Host 上 CxlSSD.img 映射出來的空間。接著 resolve_cxl_mem 計算這個模型所設定的 CXL 處理成本，ssdRead 則處理外層快取和 SSD 後端的延遲，最後把兩部分相加回傳。

所以這裡有兩個不同的問題：一個是程式能不能讀到正確資料，另一個是模型計算了多少時間。資料驗證通過，是第一個問題的證據，但不會自動證明第二個問題也建模正確。

ssdRead 內還會先檢查 CxlMemory 自己的外層快取。命中就提早回傳；miss 路徑才建立 SimpleSSD 請求，呼叫 HIL。SimpleSSD 後面又有 ICL 快取、FTL 和 NAND 模型，所以呼叫到 HIL，也不等於每次一定真的走到 NAND。

沿著這條路徑，我接下來檢查的是：回傳的延遲從哪裡來，以及 CPU 的小請求如何換成 SSD 後端使用的頁面請求。

### 程式碼證據／備用說明

- [FSConfig.py:462](/home/weiting/CXL-SSD-Sim/configs/common/FSConfig.py:462)：建立 MemBus、IOBus 與 Bridge 並接線。
- [SouthBridge.py:101](/home/weiting/CXL-SSD-Sim/src/dev/x86/SouthBridge.py:101)：`self.cxlmemory.pio = bus.mem_side_ports`。
- [cxl_memory.cc:230](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:230)：`CxlMemory::read()`。
- [cxl_memory.cc:370](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:370)：一般讀／寫的資料處理。
- [cxl_memory.cc:419](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:419)：外層快取 hit 提早返回；455 行呼叫 `pHIL->read(request)`。

CPU cache、CxlMemory 外層 cache、SimpleSSD ICL cache 是不同層。不是所有 CPU load 都會到達裝置。

## 第 4 頁｜三個實作觀察：固定延遲、寫回 TODO 與粒度換算

### 投影片內容

主投影片保留三列，依序顯示；下方的程式碼展開放講者備忘或備用畫面。

| 觀察 | 程式碼證據 | 目前可下的結論 |
|---|---|---|
| CXL 處理成本固定 | `return cxl_mem_latency_;`，預設 25 ns | 此成本項目採固定延遲抽象，需確認是否符合研究目標 |
| Dirty page 寫回 TODO | `storage_latency += 35250000;` | 已呼叫 SimpleSSD，但這個寫回成本仍使用硬編碼常數 |
| Packet／頁面粒度換算 | `nlp = pkt->getSize() / logical_page_size_;` | 接合層頁面為 1 KiB；若收到 64 B Packet，整數除法得到零頁 |

頁尾結論：三者分別是「模型簡化」「局部待修正處理」「待動態確認的換算問題」，尚不能據此判定整個專案失效，或解釋 8/21 的 Host 耗時。

### 完整講稿

第一個觀察是 CXL 處理成本。resolve_cxl_mem 最後回傳 cxl_mem_latency，Python 預設是 25 ns。也就是說，這個函式用固定參數表示這部分成本。固定值本身不代表沒做完，因為模擬器可以依研究目標選擇細節程度；例如只研究裝置快取大小的影響，可以先固定介面成本。但如果要研究協定流量控制或壅塞，單靠這個常數就不足以描述那些變化。另外，這不是整條存取的總時間，bus、Bridge 與儲存模型仍有各自的成本。

第二個觀察比較明確，是外層快取的 dirty page 寫回。Dirty 表示快取裡的資料修改過，替換出去前需要寫回後端。我看到程式先建立 write_latency 變數，把它的位址交給 SimpleSSD 請求，也確實呼叫了 pHIL->write。但之後累加到 storage_latency 的不是這個變數，而是 35250000 這個常數，旁邊還寫著 TODO，要修正 patch 並取得實際延遲。

這可以支持的結論是：目前版本這條寫回路徑的延遲整合仍使用暫時常數。不能擴大成 SimpleSSD 所有延遲都固定，因為同一個函式的一般讀取 miss 路徑，使用的是 read_latency 乘以 10；這個倍率的時間單位或校準依據也值得另查。固定寫回成本的影響，還要看 workload 有多少次 dirty eviction。若很少觸發，直接影響可能有限；若頻繁觸發，就需要特別驗證。

第三個觀察是粒度。粒度是一次操作或管理資料的單位大小。CPU cache line、到達裝置的 Packet 大小、CxlMemory 管理的頁面，以及 NAND 實體頁面，是不同概念，不能因為都叫 page 或 block 就當成同一個大小。8/21 設定的 CPU cache line 是 64 bytes，但實際抵達裝置的 Packet 是否為 64 bytes，仍要記錄確認。

目前 CxlMemory 的頁面巨集使用一左移十位，也就是 1024 bytes；旁邊註解卻寫 4K，兩者不一致。接著程式用 Packet 大小除以這個頁面大小，計算 nlp，也就是請求描述的邏輯頁面數。如果實際 Packet 是 64 bytes，因為是整數除法，64 除以 1024 就會得到零。

值得注意的是，一筆只有 64 bytes 的請求，通常仍然會碰到某一個頁面；「不到一頁」不等於「沒有碰到任何頁」。我往後追到 ICL，看到逐頁處理迴圈是用 nlp 作為上限。如果 ICL 實際收到的是零，該次迴圈就不會執行其中的 pCache->read。不過函式後面仍然可能加上固定處理成本，所以也不能直接說總延遲一定為零。

目前我已經確認常數、除法和迴圈的寫法，但還沒有用本次 trace 證明實際 workload 觸發了這整條情況。下一步要一起記錄 Packet 大小、頁面大小、offset、nlp 和後端呼叫，才能判斷實際影響。

因此我會把這三項當作模型適用範圍與重現時的驗證重點。對作者是否做完，我目前只能說這個版本有明確的寫回 TODO，並有需要釐清的粒度換算；還不能推論論文實驗用了相同版本，也不能把它們直接認定為大實驗跑很久的原因。接下來用 8/21 的 log 說明目前確實完成的部分。

### 程式碼展開：dirty page 寫回

以下為 `ssdRead()` 的 dirty page 分支節錄，省略請求欄位設定；`ssdWrite()` 也有相同的固定成本。

```cpp
uint64_t write_latency = 0;
SimpleSSD::HIL::Request write_back_request(&write_latency);
// 設定頁面地址、數量與長度……
pHIL->write(write_back_request);

storage_latency += 35250000; // TODO: need fix this patch, get real latency
```

`35250000` 是程式累加的時間數值，不能直接寫成 35,250,000 ns。若以 gem5 的 1 ps/tick 時基解讀，才對應 35.25 μs；實驗中仍需確認時基與 SimpleSSD 接合的單位。一般讀取路徑另有 `storage_latency += read_latency * 10`，所以兩者需要分開追。

### 程式碼展開：粒度換算

```cpp
// cxl_memory.hh：目前接合層的定義
#define CXL_SSD_PAGE_LEFT_BITS (10)
#define CXL_SSD_PAGE_SIZE (1LL << CXL_SSD_PAGE_LEFT_BITS) // 4K capacity
uint32_t logical_page_size_{CXL_SSD_PAGE_SIZE};

// cxl_memory.cc：請求欄位
request.range.slpn = ssd_start / logical_page_size_;
request.range.nlp = pkt->getSize() / logical_page_size_;
request.offset = ssd_start % logical_page_size_;
request.length = pkt->getSize();
```

- `slpn`：起始邏輯頁號；`offset`：起始位置在該頁內的偏移。
- `nlp`：邏輯頁面數；`length`：請求的 byte 數。
- 接合層目前使用 1 KiB，不代表 SimpleSSD 的 NAND 實體頁面也一定是 1 KiB；還需核對後端配置與請求介面約定。
- 概念上，非零長度請求覆蓋的頁數取決於起始 offset 與長度。若介面要求計算覆蓋頁數，可用 `ceil((offset + length) / page_size)` 理解，但不能未確認介面就直接把它當成修補方案。
- 例：頁面 1024 B、offset 0、length 64 B，覆蓋 1 頁；offset 1000、length 64 B，會跨到第 2 頁。單純 `length / page_size` 的向下取整無法表達這兩種情況。
- 即使把巨集改成 4 KiB，`64 / 4096` 仍是 0，因此只改大小不能自動解決換算問題。

```cpp
// icl.cc：逐頁處理的控制條件（節錄）
for (uint64_t i = 0; i < req.range.nlp; i++) {
    // 設定子請求……
    pCache->read(reqInternal, beginAt);
}
```

### 程式碼證據／備用說明

- [CxlMemory.py:10](/home/weiting/CXL-SSD-Sim/src/dev/storage/CxlMemory.py:10)：`latency=50ns`、`cxl_mem_latency=25ns`。
- [cxl_memory.cc:298](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:298)：`resolve_cxl_mem()`。
- [cxl_memory.cc:424](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:424)：讀取 miss 的 dirty page 分支，439 行累加固定寫回成本。
- [cxl_memory.cc:486](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:486)：寫入 miss 的 dirty page 分支，501 行使用相同常數。
- [cxl_memory.cc:455](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:455)：一般讀取 miss 使用 `read_latency * 10`。
- [cxl_memory.hh:24](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.hh:24)：頁面常數；411 行初始化 `logical_page_size_`。
- [cxl_memory.cc:450](/home/weiting/CXL-SSD-Sim/src/dev/storage/cxl_memory.cc:450)：頁面數計算。
- [icl.cc:75](/home/weiting/CXL-SSD-Sim/src/dev/storage/simplessd/icl/icl.cc:75)：ICL 以 `req.range.nlp` 控制逐頁處理迴圈。需確認傳入值，才可判斷是否跳過這段迴圈。

本頁是目前 source 的檢查結果；沒有證據把這些疑點直接判定為 8/21 長時間執行的原因，也沒有確認論文使用的 executable 與目前 source 完全相同。

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

### 完整講稿

這頁整理的是 8/21 那次長時間執行留下的輸出，資料來自 o3-full-20260821 這個目錄。雖然我沒有完成整套測試，但重新看完整 Guest log 後，可以確認它已經完成幾個子測試，因此這裡報告實際完成的範圍。

保存的設定顯示 Guest RAM 是 512 MiB，CXL 裝置 BAR 容量是 4 GiB，L1 instruction 和 data cache 各 32 KiB，L2 是 512 KiB。Guest 文字輸出標示 O3；初始化設定則同時包含 Atomic CPU 和待切換的 O3 CPU，所以我把 CPU runtime 切換紀錄列為後續需要補齊的資訊。

STREAM 的每個 array 有一百萬個元素，每個元素八個 bytes，三個 array 合計約 22.9 MiB，每個 kernel 執行十次。表格是它輸出的 Best Rate，依原始 log 的 finish 標記分成 DRAM 和 CXL 兩組。例如 Copy 分別是 1839.1 和 353.5 MB/s，Triad 分別是 2746.7 和 606.3 MB/s。這裡量到的是 Guest 內程式的頻寬，不是 Host 執行模擬器的吞吐率。

兩組後面都有 Solution Validates，以及對應的 finish 標記，所以可以說這兩段 STREAM 已經完成，而且計算結果通過程式自己的資料檢查。接著兩組 membench 也印出結果與完成標記。再往後，log 顯示建立 /dev/cxl_mem0 的 pool，然後進入 START PREFILL；最後是 Ctrl+C 和 Guest shell，沒有整套 FULL BENCHMARK END 標記。

因此目前可報告的是：部分 workload 已完成，較後面的預填階段被中斷，整套 benchmark 尚未完成。資料檢查通過不能取代延遲模型驗證，也不能單憑這張表說所有 CXL 存取都真的走到 NAND，或把頻寬差異完全歸因於 SSD。

這次保存的 stats.txt 仍是空的，缺少完整 gem5 統計和各階段的 Host 耗時。這表示目前無法精確回答哪一階段消耗多少時間，也不能只靠空檔判斷卡死。因此下一步會把 benchmark 分開，讓每段都有完成標記與統計，再逐步擴大規模。

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
3. **確認後端與寫回成本**：追 HIL／ICL／FTL 呼叫；檢查零頁請求，並量測 dirty eviction 次數、`write_latency` 與實際累加值。
4. **分段跑效能測試**：先單獨完成 STREAM；較大 workload 從小規模 prefill 開始，分階段保存統計並量測 Host 耗時。

預期交付：一份可解釋的 request trace、一個完整結束的小型測試、一份分階段執行成本紀錄。

### 完整講稿

根據目前的程式碼觀察和執行結果，我把下一步分成四個工作。

第一，補齊可重現資訊。除了啟動命令和 config，我也要保存 commit、執行檔資訊、Guest benchmark 腳本與參數，以及 Host 和 Guest 的輸出。這樣才能把某次 trace 或效能結果，對應回當時真正使用的程式版本，避免把不同次實驗混在一起。

第二，先做一個小型存取實驗。在 CxlMemory 入口記錄地址與 Packet 大小，再記錄外層 cache hit 或 miss、頁面大小、offset 和 nlp。這裡要小心，重複讀同一地址可能只命中 CPU cache，所以我要確認請求真的抵達裝置，才能研究裝置快取的行為。

第三，針對第四頁的問題補上動態證據。粒度部分，確認實際是否產生零頁請求，以及 ICL 和後面的 FTL 是否被呼叫。寫回部分，安排能觸發 dirty eviction 的小型案例，記錄後端提供的 write_latency 和接合層實際累加的值，確認時間單位與執行時序。先把這些行為看清楚，再決定是否需要修改模型或做參數敏感度測試。

第四，把整套 benchmark 拆開執行。先單獨完成 STREAM 並保存統計，再從較小的 prefill 規模開始，記錄每個階段的 Host 耗時與模擬進度。縮小 workload 可以幫助確認流程，但會改變 cache 行為，因此小規模結果不直接代替論文的大規模效能結果。

下一次預計交付三樣東西：一筆可以逐欄解釋的請求 trace、一個正常完成且有統計的小型測試，以及分階段的執行成本紀錄。這些證據能幫助判斷模型疑點，也能讓後續大實驗的時間安排有依據。

### 實驗設計提醒

- 重複讀同一地址可能只命中 CPU cache；必須在 CxlMemory 入口確認請求是否到達。
- TimingSimpleCPU 可先用於功能／路徑驗證，但它的效能數字不能直接當 O3 結果。
- 縮小 workload 會改變 cache hit 行為；小實驗通過不等於原始規模結果已重現。
- Debug trace 本身有成本：小型診斷開 trace，正式計時需控制記錄開銷。
- 本文件僅整理報告與後續計畫，以上新實驗尚未執行。

## 報告問答備忘（不計入六頁）

**固定延遲代表作者沒做完嗎？**

要區分情況。CXL 固定參數可能是有意的模型簡化，需要看研究目標與校準依據。Dirty page 寫回則有明確 TODO，且實際累加常數而未使用該次 `write_latency`，因此可說目前版本的這條延遲整合仍待修正或釐清。不能據此推論整個專案沒完成，更不能未核對版本就把它當成論文結果無效的證據。

**SimpleSSD 的延遲全部固定嗎？**

不能這樣說。確認到的是 CxlMemory 接合層的 dirty page 寫回成本固定；一般讀取 miss 使用 `read_latency * 10`。後端是否按預期算出逐請求延遲，以及倍率依據，需要另外驗證。

**粒度問題是不是 CPU 用 64 B、SSD 用 4 KiB，所以本來就不能接？**

不同粒度本身正常，接合層需要正確描述起始頁、頁內偏移、長度與頁數。目前具體疑點是接合層常數算出 1 KiB、註解寫 4K，以及頁數使用向下取整除法，可能把小請求變成零頁。不要把接合層常數直接當成 NAND 物理頁大小。

**改成 4 KiB 或改用向上取整就一定好了嗎？**

只改成 4 KiB，64 除以 4096 仍然為零。向上取整也要考慮 offset 和跨頁，並先確認 SimpleSSD 介面要求、cache fill 粒度及單位一致性。現在先提出可驗證的問題，尚未宣稱已找到完整修補方案。

**零頁請求一定讓總延遲為零嗎？**

不一定。若 ICL 收到 nlp=0，逐頁迴圈不會執行，但後面仍有 ICL 處理成本；外層也有其他固定延遲。更精確的問題是：預期的後端頁面處理是否被略過，而不是總延遲是否必然為零。

**這些問題解釋了 8/21 為什麼跑很久嗎？**

目前沒有這個證據。模型回傳的延遲是模擬時間；Host 花多少時間執行則還取決於指令與事件數、模型計算、記錄開銷和 workload 規模。需要實際執行紀錄才能建立因果關係。

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
