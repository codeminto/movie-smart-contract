# 🏪 Aptos NFT Rental Marketplace

This module implements a **decentralized NFT rental marketplace** on the **Aptos blockchain**, enabling users to **list, rent, and manage NFTs** with support for collateral, automatic returns, platform fees, and configurable admin controls.

---

## ⚙️ Features

- 📝 **List NFTs for Rent** – Set daily price, duration, and optional collateral.
- 🤝 **Rent NFTs** – Securely rent NFTs with escrowed payments and collateral.
- 💰 **Payments & Collateral** – Built-in AptosCoin payments with platform fee logic.
- 🔄 **Return Early** – Renter can return NFTs early and receive refund.
- ⏳ **Auto Return** – Owner can reclaim NFTs after rental expires.
- 🛑 **Pause/Unpause Market** – Admin controls to pause/unpause activity.
- 📈 **Platform Fee Configurable** – Adjustable via basis points (default 2.5%).
- 👀 **View Functions** – Public view functions for listings, rentals, and expiration status.

---

## 🧱 Data Structures

### 📦 Listing
```move
struct Listing {
  owner: address,
  nft_id: String,
  price_per_day: u64,
  max_duration_days: u64,
  collateral_required: u64,
  is_active: bool,
  created_at: u64,
}
```

### 📄 RentalRecord
```move
struct RentalRecord {
  renter: address,
  original_owner: address,
  nft_id: String,
  rental_start: u64,
  rental_end: u64,
  daily_price: u64,
  total_paid: u64,
  collateral_paid: u64,
  is_active: bool,
}
```

### 🔐 RentalCapability
Grants access to use a rented NFT until expiration.

---

## 📑 Core Functions

| Function | Description |
|---------|-------------|
| `initialize()` | Setup marketplace with admin and treasury address. |
| `list_for_rent()` | List an NFT with price, duration, and collateral. |
| `rent_nft()` | Rent an NFT, paying total price + collateral. |
| `return_nft_early()` | Early return by renter with proportional refund. |
| `claim_expired_nft()` | Owner reclaims NFT after rental expiry. |
| `pause_marketplace()` / `unpause_marketplace()` | Admin control to halt/resume activity. |
| `update_platform_fee()` | Adjust platform fee (in basis points). |

---

## 💸 Payment Logic

- **Total Cost** = `price_per_day * days`
- **Platform Fee** = `total_cost * fee_bps / 10000`
- **Owner Gets** = `total_cost - fee`
- **Collateral**: Held and returned upon early return or expiry

---

## 📊 View Functions

- `get_listing(nft_id, admin)`: Returns listing info.
- `get_rental_info(nft_id, admin)`: Returns rental record.
- `is_rental_expired(nft_id, admin)`: True if rental has expired.
- `get_platform_fee()`: Returns platform fee (basis points).

---

## 🔐 Admin Management

```move
struct MarketplaceConfig {
  admin: address,
  is_paused: bool,
  platform_fee_basis_points: u64,
  treasury: address,
}
```

- Only `admin` can:
  - Pause/unpause
  - Update fee
  - Initialize contract

---

## 🧪 Testing Utilities

```move
#[test_only]
fun init_for_test(admin: &signer, treasury: address)

#[test_only]
fun get_listing_count(admin: address): u64
```

---

## 📦 Events

| Event | Description |
|-------|-------------|
| `ListedEvent` | Emitted when NFT is listed |
| `RentedEvent` | Emitted when NFT is rented |
| `ReturnedEvent` | On early return |
| `ExpiredAutoReturnEvent` | When owner reclaims after expiry |

---

## 📚 Dependencies

- `aptos_framework::account`, `aptos_framework::aptos_coin::AptosCoin`
- `aptos_std::table`, `math64`
- `std::timestamp`, `signer`, `vector`, `string`, `option`

---

## 🧠 Use Cases

- 🔐 Subscription Access NFTs  
- 🎮 In-game Assets Renting  
- 🎨 Digital Art & Media Leasing  
- 🎟️ Ticket Rentals  

---

## 📜 License

MIT

---

Built with ❤️ for the Aptos ecosystem.
