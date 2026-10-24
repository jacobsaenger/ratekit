# RateKit

The pricing engine behind [Your Real Rate](https://yourrealrate.pages.dev), a free iPhone app that compares
Texas residential electricity plans. It's published so anyone can check how plans are priced and ranked,
and that payments from providers play no part in it.

RateKit is a Swift package with no dependencies beyond Foundation, so it builds on macOS and Linux. It has two
parts:

- **`RateKit`**, the library: it reads each plan's Electricity Facts Label, checks it against the prices
  the plan publishes on Power to Choose, and prices every plan for a household's own year of usage.
- **`ratefeed`**, the command-line tool that builds the daily plan file the app downloads.

## How a plan gets ranked

1. **Every residential plan:** `ratefeed` downloads Power to Choose's export of every residential plan
   (`PowerToChooseCSV`).
2. **Reading the label:** for each plan it reads the Electricity Facts Label: energy charges, base
   charges, bill credits and their usage limits, minimum-usage fees, one-time fees, and delivery charges
   (`LabelParser`).
3. **Checking the label:** a plan is **verified** only if the terms read from its label reproduce all
   three average prices it advertises on Power to Choose (500, 1,000 and 2,000 kWh) within 0.1¢ per kWh
   (`PlanVerifier`).
   - Plans that miss are marked **estimated**. They are never ranked.
   - The tolerance is never loosened to pass more plans.
4. **Delivery charges:** your utility's delivery charges are added at their current rates
   (`TDUCharges.current`, `PlanRanking.withCurrentDelivery`). They are passed through to every customer
   at cost, whatever an older label printed.
5. **Your usage:** each verified plan is priced month by month for the household's own 12 months of
   usage (`CostEngine`), and plans are sorted by that yearly cost (`PlanRanking`). A plan built to look
   cheap at exactly 1,000 kWh only wins if it's cheap at your usage.

## Payments never touch the ranking

When a provider pays a referral fee, the app says so on that provider's plans. That information
travels in the plan file as `Feed.referralFees`, a list of provider names and what each pays, and is
only displayed. `PlanRanking` never reads it. You can confirm this with a search:

```bash
grep -rn referralFee Sources/RateKit
```

The only hits are the field itself and its lookup in `Models/Feed.swift`.

## Build and test

```bash
swift test
```

The tests include Electricity Facts Labels and a Power to Choose export (`Tests/RateKitTests/Fixtures`).
These are public documents that Texas providers are required to publish. A fixture test reads every
label in the fixtures and fails if any label that used to verify stops verifying.

To build a plan file yourself (the first run downloads about 900 labels and takes about an hour):

```bash
brew install poppler   # pdftotext, used to read the label PDFs
swift build -c release
.build/release/ratefeed build --cache cache --out feed.json --report report.txt
.build/release/ratefeed price feed.json centerPoint house1500to1999 10
```

`price` prints the ten cheapest plans for a typical 1,500–1,999 sq ft Houston house, with each yearly cost.

## What it doesn't do

- **Business plans and taxes.** It prices residential plans only, and costs don't include taxes.
- **Time-of-use plans.** Plans that charge by time of day are priced only for households with a year of
  15-minute or hourly meter data (`TimeOfUseReader`, `UsageProfile`). Otherwise they're listed, not ranked.
- **Unverified plans.** About 1 in 20 plans can't be verified on a given day, usually because the label's
  wording isn't recognised or the provider hasn't updated its published prices. Those are listed with
  their advertised prices, never ranked as cheapest.

## License

MIT. See [LICENSE](LICENSE). Published by Nova Meridia LLC.
