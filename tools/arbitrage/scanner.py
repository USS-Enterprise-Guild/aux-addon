#!/usr/bin/env python3
"""
WoW Auction Arbitrage Scanner

Fetches auction data from wowauctions.net and identifies arbitrage opportunities:
1. Vendor flips: Items listed below vendor sell price
2. Market flips: Items listed significantly below historical average

Usage:
    python scanner.py [--server turtle-wow] [--realm nordanaar] [--faction alliance]
"""

import argparse
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import quote

import requests
from bs4 import BeautifulSoup


@dataclass
class AuctionData:
    item_id: int
    item_name: str
    amount_listed: int
    min_buyout: int  # in copper
    avg_price: int   # in copper
    vendor_price: int  # in copper
    last_scan: str


@dataclass
class ArbitrageOpportunity:
    item_id: int
    item_name: str
    opportunity_type: str  # 'vendor' or 'market'
    current_price: int
    target_price: int  # vendor price or avg market price
    profit_per_item: int
    amount_available: int
    total_potential_profit: int
    roi_percent: float


class WowAuctionsScraper:
    BASE_URL = "https://www.wowauctions.net"

    def __init__(self, server: str = "turtle-wow", realm: str = "nordanaar", faction: str = "alliance"):
        self.server = server
        self.realm = realm
        self.faction = faction
        self.session = requests.Session()
        self.session.headers.update({
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        })

    def _make_slug(self, item_name: str) -> str:
        """Convert item name to URL slug."""
        slug = item_name.lower()
        slug = re.sub(r'[^a-z0-9\s-]', '', slug)
        slug = re.sub(r'\s+', '-', slug)
        return slug

    def _parse_copper(self, price_str: str) -> int:
        """Parse price string like '99g 99s 99c' to copper."""
        if not price_str:
            return 0

        copper = 0
        gold_match = re.search(r'(\d+)g', price_str)
        silver_match = re.search(r'(\d+)s', price_str)
        copper_match = re.search(r'(\d+)c', price_str)

        if gold_match:
            copper += int(gold_match.group(1)) * 10000
        if silver_match:
            copper += int(silver_match.group(1)) * 100
        if copper_match:
            copper += int(copper_match.group(1))

        return copper

    def fetch_item(self, item_id: int, item_name: str) -> Optional[AuctionData]:
        """Fetch auction data for a specific item."""
        slug = self._make_slug(item_name)
        url = f"{self.BASE_URL}/auctionHouse/{self.server}/{self.realm}/{self.faction}/{slug}-{item_id}"

        try:
            response = self.session.get(url, timeout=10)
            if response.status_code == 404:
                return None
            response.raise_for_status()

            soup = BeautifulSoup(response.text, 'html.parser')

            # Find the Next.js data script
            script_tag = soup.find('script', {'id': '__NEXT_DATA__'})
            if not script_tag:
                return None

            data = json.loads(script_tag.string)
            page_props = data.get('props', {}).get('pageProps', {})
            item_data = page_props.get('item', {})

            item_info = item_data.get('item_info', {})
            stats = item_data.get('stats', {})

            if not stats:
                return None

            # Extract vendor price from item_info.SellPrice (in copper)
            vendor_price = item_info.get('SellPrice', 0)

            return AuctionData(
                item_id=item_id,
                item_name=item_name,
                amount_listed=stats.get('item_count', 0),
                min_buyout=stats.get('minimum_buyout', 0),
                avg_price=stats.get('avg_price', 0),
                vendor_price=vendor_price,
                last_scan=stats.get('item_last_seen', '')
            )

        except Exception as e:
            print(f"Error fetching {item_name} ({item_id}): {e}")
            return None

    def scan_items(self, items: list[tuple[int, str]], delay: float = 0.5) -> list[AuctionData]:
        """Scan multiple items with rate limiting."""
        results = []
        total = len(items)

        for i, (item_id, item_name) in enumerate(items, 1):
            print(f"[{i}/{total}] Scanning: {item_name}...")
            data = self.fetch_item(item_id, item_name)
            if data and data.amount_listed > 0:
                results.append(data)
            time.sleep(delay)

        return results


class ArbitrageDetector:
    # AH cut is 5% on Turtle WoW
    AH_CUT = 0.05
    # Minimum profit threshold (in copper) - 10 silver
    MIN_PROFIT = 1000
    # Market discount threshold - items must be at least 30% below avg
    MARKET_DISCOUNT_THRESHOLD = 0.70

    def __init__(self, min_profit: int = 1000, market_threshold: float = 0.70):
        self.min_profit = min_profit
        self.market_threshold = market_threshold

    def detect_vendor_flip(self, auction: AuctionData) -> Optional[ArbitrageOpportunity]:
        """Detect if item can be bought and vendored for profit."""
        if auction.vendor_price <= 0:
            return None

        # Profit = vendor_price - buy_price
        profit = auction.vendor_price - auction.min_buyout

        if profit >= self.min_profit:
            return ArbitrageOpportunity(
                item_id=auction.item_id,
                item_name=auction.item_name,
                opportunity_type='vendor',
                current_price=auction.min_buyout,
                target_price=auction.vendor_price,
                profit_per_item=profit,
                amount_available=auction.amount_listed,
                total_potential_profit=profit * auction.amount_listed,
                roi_percent=(profit / auction.min_buyout * 100) if auction.min_buyout > 0 else 0
            )
        return None

    def detect_market_flip(self, auction: AuctionData) -> Optional[ArbitrageOpportunity]:
        """Detect if item is significantly below market average."""
        if auction.avg_price <= 0 or auction.min_buyout <= 0:
            return None

        # Check if price is below threshold of average
        if auction.min_buyout > auction.avg_price * self.market_threshold:
            return None

        # Calculate potential profit (accounting for AH cut when reselling)
        resale_price = auction.avg_price
        net_resale = resale_price * (1 - self.AH_CUT)
        profit = int(net_resale - auction.min_buyout)

        if profit >= self.min_profit:
            return ArbitrageOpportunity(
                item_id=auction.item_id,
                item_name=auction.item_name,
                opportunity_type='market',
                current_price=auction.min_buyout,
                target_price=auction.avg_price,
                profit_per_item=profit,
                amount_available=auction.amount_listed,
                total_potential_profit=profit * auction.amount_listed,
                roi_percent=(profit / auction.min_buyout * 100)
            )
        return None

    def analyze(self, auctions: list[AuctionData]) -> list[ArbitrageOpportunity]:
        """Analyze all auctions for arbitrage opportunities."""
        opportunities = []

        for auction in auctions:
            vendor_opp = self.detect_vendor_flip(auction)
            if vendor_opp:
                opportunities.append(vendor_opp)

            market_opp = self.detect_market_flip(auction)
            if market_opp:
                opportunities.append(market_opp)

        # Sort by total potential profit descending
        opportunities.sort(key=lambda x: x.total_potential_profit, reverse=True)
        return opportunities


def format_copper(copper: int) -> str:
    """Format copper amount as gold/silver/copper string."""
    gold = copper // 10000
    silver = (copper % 10000) // 100
    copper_rem = copper % 100

    parts = []
    if gold > 0:
        parts.append(f"{gold}g")
    if silver > 0:
        parts.append(f"{silver}s")
    if copper_rem > 0 or not parts:
        parts.append(f"{copper_rem}c")

    return " ".join(parts)


def export_for_aux(opportunities: list[ArbitrageOpportunity], output_path: Path):
    """Export opportunities in a format that can be imported by Aux addon."""
    # Export as simple item list that Aux can search for
    items = []
    for opp in opportunities:
        items.append({
            'id': opp.item_id,
            'name': opp.item_name,
            'type': opp.opportunity_type,
            'profit': opp.profit_per_item,
            'roi': opp.roi_percent
        })

    with open(output_path, 'w') as f:
        json.dump(items, f, indent=2)

    # Also export as simple text list for easy copying
    text_path = output_path.with_suffix('.txt')
    with open(text_path, 'w') as f:
        f.write("# Arbitrage Candidates - Search these in Aux\n")
        f.write("# Format: item_name (type: profit)\n\n")
        for opp in opportunities:
            f.write(f"{opp.item_name} ({opp.opportunity_type}: {format_copper(opp.profit_per_item)} profit)\n")


def main():
    parser = argparse.ArgumentParser(description='WoW Auction Arbitrage Scanner')
    parser.add_argument('--server', default='turtle-wow', help='Server name')
    parser.add_argument('--realm', default='nordanaar', help='Realm name')
    parser.add_argument('--faction', default='alliance', help='Faction (alliance/horde)')
    parser.add_argument('--min-profit', type=int, default=1000, help='Minimum profit in copper (default: 1000 = 10s)')
    parser.add_argument('--delay', type=float, default=0.5, help='Delay between requests in seconds')
    parser.add_argument('--output', default='arbitrage_candidates.json', help='Output file path')
    args = parser.parse_args()

    # Load item database
    items_file = Path(__file__).parent / 'items.json'
    if not items_file.exists():
        print(f"Error: Item database not found at {items_file}")
        print("Please create items.json with format: [[item_id, \"Item Name\"], ...]")
        return

    with open(items_file) as f:
        items = json.load(f)

    print(f"Loaded {len(items)} items to scan")
    print(f"Server: {args.server}, Realm: {args.realm}, Faction: {args.faction}")
    print()

    # Scan items
    scraper = WowAuctionsScraper(args.server, args.realm, args.faction)
    auctions = scraper.scan_items(items, delay=args.delay)

    print(f"\nFound {len(auctions)} items with active listings")

    # Detect arbitrage
    detector = ArbitrageDetector(min_profit=args.min_profit)
    opportunities = detector.analyze(auctions)

    print(f"Found {len(opportunities)} arbitrage opportunities\n")

    # Display results
    if opportunities:
        print("=" * 80)
        print("ARBITRAGE OPPORTUNITIES")
        print("=" * 80)

        for opp in opportunities[:20]:  # Show top 20
            print(f"\n{opp.item_name} (ID: {opp.item_id})")
            print(f"  Type: {opp.opportunity_type.upper()}")
            print(f"  Current Price: {format_copper(opp.current_price)}")
            print(f"  Target Price: {format_copper(opp.target_price)}")
            print(f"  Profit/Item: {format_copper(opp.profit_per_item)} ({opp.roi_percent:.1f}% ROI)")
            print(f"  Available: {opp.amount_available}")
            print(f"  Total Potential: {format_copper(opp.total_potential_profit)}")

        # Export results
        output_path = Path(args.output)
        export_for_aux(opportunities, output_path)
        print(f"\nExported {len(opportunities)} opportunities to {output_path}")


if __name__ == '__main__':
    main()
