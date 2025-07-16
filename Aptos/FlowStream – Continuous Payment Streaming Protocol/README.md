# 🚀 FlowStream

**FlowStream** is an on-chain payment streaming protocol built on the **Aptos blockchain** using the **Move language**. It enables real-time token distribution between users, supporting use cases like salary payments, token vesting, subscriptions, and continuous rewards.

---

## 🧠 Features

- ⏱️ **Continuous Streaming**: Stream tokens over time between sender and recipient.
- 💸 **Withdraw Anytime**: Recipients can withdraw tokens proportional to elapsed time.
- 🔁 **Top-Up Streams**: Senders can add funds to ongoing streams.
- ⏸️ **Pause & Resume**: Temporarily pause and later resume a stream (v2 feature).
- ❌ **Stream Cancellation**: Cancel a stream anytime with refund and balance calculation.
- 🔍 **On-Chain View Functions**: Get stream details, balances, and withdrawable amounts.
- 🛡️ **Safe Math Utilities**: Utility module ensures overflow-free calculations and rounding.

---

## 🏗️ Built With

- **Aptos Move** – Smart contract programming language on Aptos  
- **Aptos Framework** – For coin transfers, events, timestamp handling  
- **Aptos Stdlib** – Tables, type introspection, and safe utilities  

---

## 🔧 Stream Lifecycle

1. **Create Stream**
2. **Withdraw as Recipient**
3. **Top-Up as Sender**
4. **Pause/Resume (Optional)**
5. **Cancel with Refund**

---

## 🧪 Example Use Cases

- 💼 Real-time payroll for employees  
- 🎟️ Subscription services with per-second billing  
- ⛓️ Token vesting for projects  
- 💰 Streaming grants or bounties  

---

## 🧱 Core Components

### 📦 `Stream<T>`
> Stores all the stream data like sender, recipient, rate, start/end time, balances, status.

### 📦 `StreamManager`
> Maintains global stream IDs and mapping between stream ID and sender.

### 📦 Utility Module (`utils`)
> Safe math functions, overflow checks, percentage calculation, time conversion.

---

## 📜 Error Codes

| Code | Description |
|------|-------------|
| 1    | Stream not found |
| 2    | Unauthorized |
| 3    | Invalid parameters |
| 4    | Insufficient balance |
| 5    | Stream already ended |
| 6    | Stream not started |
| 7    | Nothing to withdraw |
| 8    | Invalid time range |

---

## 📈 View Functions

- `get_stream_info` – Full details of a stream  
- `get_withdrawable_amount` – How much recipient can withdraw  
- `get_stream_balance` – Current stream balance  

---

## 🪙 Coin Support

Works with **any Aptos-compatible coin**, just parameterized by type:
```move
create_stream<USDC>(...)
```

---

## 🧑‍💻 Getting Started

1. **Deploy** the `FlowStream` and `utils` module to your Aptos account  
2. Call `init_module()` once to initialize  
3. Start creating streams with `create_stream<T>`

---

## 📚 License

MIT License © Dhruv Dobariya
