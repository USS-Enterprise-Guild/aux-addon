module 'aux.tabs.arbitrage'

local aux = require 'aux'
local info = require 'aux.util.info'
local money = require 'aux.util.money'
local gui = require 'aux.gui'
local listing = require 'aux.gui.listing'
local al = require 'aux.gui.auction_listing'

function aux.handle.INIT_UI()
    local THEME_PADDING = gui.is_blizzard() and 6.5 or 2.5

    frame = CreateFrame('Frame', nil, aux.frame)
    frame:SetAllPoints()
    frame:SetScript('OnUpdate', on_update)
    frame:Hide()

    frame.content = CreateFrame('Frame', nil, frame)
    frame.content:SetPoint('TOP', frame, 'TOP', 0, -8)
    frame.content:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, 0)
    frame.content:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

    -- Left panel: Candidate list
    frame.candidates = gui.panel(frame.content)
    frame.candidates:SetWidth(280)
    frame.candidates:SetPoint('TOPLEFT', 0, 0)
    frame.candidates:SetPoint('BOTTOMLEFT', 0, 0)

    -- Right panel: Results/Details
    frame.results = gui.panel(frame.content)
    frame.results:SetPoint('TOPLEFT', frame.candidates, 'TOPRIGHT', THEME_PADDING, 0)
    frame.results:SetPoint('BOTTOMRIGHT', 0, 0)

    -- Candidate list header
    do
        local label = gui.label(frame.candidates, gui.font_size.large)
        label:SetPoint('TOPLEFT', 10, -10)
        label:SetText('Arbitrage Candidates')
    end

    -- Add item input
    do
        local editbox = gui.editbox(frame.candidates)
        editbox:SetPoint('TOPLEFT', 10, -35)
        editbox:SetWidth(180)
        editbox:SetHeight(22)
        editbox.enter = function()
            local text = this:GetText()
            if text and text ~= '' then
                if add_candidate(text) then
                    this:SetText('')
                end
            end
        end
        local label = gui.label(editbox, gui.font_size.small)
        label:SetPoint('BOTTOMLEFT', editbox, 'TOPLEFT', 0, 2)
        label:SetText('Add Item (name or link)')
        add_item_input = editbox
    end

    -- Add button
    do
        local btn = gui.button(frame.candidates)
        btn:SetPoint('LEFT', add_item_input, 'RIGHT', 5, 0)
        btn:SetWidth(60)
        btn:SetText('Add')
        btn:SetScript('OnClick', function()
            local text = add_item_input:GetText()
            if text and text ~= '' then
                if add_candidate(text) then
                    add_item_input:SetText('')
                end
            end
        end)
    end

    gui.horizontal_line(frame.candidates, -70)

    -- Candidate listing
    do
        local f = CreateFrame('Frame', nil, frame.candidates)
        f:SetPoint('TOPLEFT', 0, -76)
        f:SetPoint('BOTTOMRIGHT', 0, 40)

        candidate_listing = listing.new(f)
        candidate_listing:SetColInfo{
            {name='Item', width=.55, align='LEFT'},
            {name='Type', width=.25, align='CENTER'},
            {name='', width=.20, align='CENTER'},
        }
        candidate_listing:SetSelection(function(data)
            return data.candidate == get_selected_candidate()
        end)
        candidate_listing:SetHandler('OnClick', function(table, row_data, column, button)
            if button == 'RightButton' then
                -- Remove on right-click
                remove_candidate(row_data.candidate.item_id)
            else
                select_candidate(row_data.candidate)
            end
        end)
    end

    -- Bottom buttons for candidate panel
    do
        local btn = gui.button(frame.candidates)
        btn:SetPoint('BOTTOMLEFT', 10, 10)
        btn:SetWidth(80)
        btn:SetText('Scan All')
        btn:SetScript('OnClick', function()
            scan_all_candidates()
        end)
        scan_all_button = btn
    end
    do
        local btn = gui.button(frame.candidates)
        btn:SetPoint('LEFT', scan_all_button, 'RIGHT', 5, 0)
        btn:SetWidth(80)
        btn:SetText('Clear All')
        btn:SetScript('OnClick', function()
            clear_candidates()
        end)
    end

    -- Results panel header
    do
        local label = gui.label(frame.results, gui.font_size.large)
        label:SetPoint('TOPLEFT', 10, -10)
        label:SetText('Scan Results')
        results_header = label
    end

    -- Item display
    do
        item_display = gui.item(frame.results)
        item_display:SetPoint('TOPLEFT', 10, -40)
        item_display.button:SetScript('OnEnter', function()
            local candidate = get_selected_candidate()
            if candidate then
                local itemstring = 'item:' .. candidate.item_id .. ':0:0:0'
                info.set_tooltip(itemstring, this, 'ANCHOR_RIGHT')
            end
        end)
        item_display.button:SetScript('OnLeave', function()
            GameTooltip:Hide()
        end)
    end

    -- Price info labels
    do
        local y_offset = -95
        local label_width = 200

        local label = gui.label(frame.results, gui.font_size.medium)
        label:SetPoint('TOPLEFT', 10, y_offset)
        label:SetWidth(label_width)
        current_price_label = label

        label = gui.label(frame.results, gui.font_size.medium)
        label:SetPoint('TOPLEFT', 10, y_offset - 20)
        label:SetWidth(label_width)
        vendor_price_label = label

        label = gui.label(frame.results, gui.font_size.medium)
        label:SetPoint('TOPLEFT', 10, y_offset - 40)
        label:SetWidth(label_width)
        market_price_label = label

        label = gui.label(frame.results, gui.font_size.medium)
        label:SetPoint('TOPLEFT', 10, y_offset - 70)
        label:SetWidth(label_width)
        available_label = label

        label = gui.label(frame.results, gui.font_size.large)
        label:SetPoint('TOPLEFT', 10, y_offset - 100)
        label:SetWidth(300)
        profit_label = label
    end

    -- Auction listing (cheapest auctions for selected item)
    do
        local f = CreateFrame('Frame', nil, frame.results)
        f:SetPoint('TOPLEFT', 10, -220)
        f:SetPoint('BOTTOMRIGHT', -10, 40)

        auction_listing = listing.new(f)
        auction_listing:SetColInfo{
            {name='Stack', width=.15, align='CENTER'},
            {name='Unit Price', width=.35, align='RIGHT'},
            {name='Total', width=.35, align='RIGHT'},
            {name='Time', width=.15, align='CENTER'},
        }
        auction_listing:SetHandler('OnClick', function(table, row_data, column, button)
            -- Could add selection for specific auctions
        end)
    end

    -- Status bar and buttons
    do
        status_bar = gui.status_bar(frame)
        status_bar:SetWidth(300)
        status_bar:SetHeight(25)
        status_bar:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 0, -6)
        status_bar:update_status(1, 1)
        status_bar:set_text('')
    end
    do
        local btn = gui.button(frame.results)
        btn:SetPoint('TOPLEFT', status_bar, 'TOPRIGHT', 5, 0)
        btn:SetText('Scan')
        btn:SetScript('OnClick', function()
            local candidate = get_selected_candidate()
            if candidate then
                scan_candidate(candidate)
            end
        end)
        scan_button = btn
    end
    do
        local btn = gui.button(frame.results)
        btn:SetPoint('TOPLEFT', scan_button, 'TOPRIGHT', 5, 0)
        btn:SetText('Buyout')
        btn:Disable()
        btn:SetScript('OnClick', function()
            execute_buyout()
        end)
        buyout_button = btn
    end
end

function update_candidate_listing()
    local rows = {}
    local candidates = get_candidates()

    for _, candidate in candidates do
        local result = get_scan_result(candidate.item_id)
        local status = '---'

        if result then
            local profits = calculate_profit(result)
            if profits and (profits.vendor or profits.market) then
                status = aux.color.green('PROFIT')
            elseif result.min_buyout then
                status = 'scanned'
            else
                status = aux.color.label.enabled('none')
            end
        end

        tinsert(rows, {
            cols = {
                {value = candidate.item_name},
                {value = candidate.opportunity_type},
                {value = status},
            },
            candidate = candidate,
        })
    end

    candidate_listing:SetData(rows)
end

function update_result_display()
    local candidate = get_selected_candidate()

    if not candidate then
        item_display.texture:SetTexture(nil)
        item_display.count:SetText('')
        item_display.name:SetText('Select a candidate')
        item_display.name:SetTextColor(aux.color.label.enabled())

        current_price_label:SetText('')
        vendor_price_label:SetText('')
        market_price_label:SetText('')
        available_label:SetText('')
        profit_label:SetText('')

        auction_listing:SetData({})
        scan_button:Disable()
        return
    end

    scan_button:Enable()

    -- Update item display
    local item_info = info.item(candidate.item_id)
    if item_info then
        item_display.texture:SetTexture(item_info.texture)
        item_display.name:SetText('[' .. item_info.name .. ']')
        local color = ITEM_QUALITY_COLORS[item_info.quality]
        if color then
            item_display.name:SetTextColor(color.r, color.g, color.b)
        end
    end
    item_display.count:SetText('')

    local result = get_scan_result(candidate.item_id)

    if not result then
        current_price_label:SetText('Current Price: Not scanned')
        vendor_price_label:SetText('Vendor Price: ---')
        market_price_label:SetText('Market Price: ---')
        available_label:SetText('Available: ---')
        profit_label:SetText('Click "Scan" to check prices')
        auction_listing:SetData({})
        return
    end

    -- Update price labels
    if result.min_buyout then
        current_price_label:SetText('Current Price: ' .. money.to_string(result.min_buyout, true))
    else
        current_price_label:SetText('Current Price: None listed')
    end

    if result.vendor_price and result.vendor_price > 0 then
        vendor_price_label:SetText('Vendor Price: ' .. money.to_string(result.vendor_price, true))
    else
        vendor_price_label:SetText('Vendor Price: None')
    end

    if result.historical_value and result.historical_value > 0 then
        market_price_label:SetText('Market Price: ' .. money.to_string(result.historical_value, true))
    else
        market_price_label:SetText('Market Price: No history')
    end

    available_label:SetText('Available: ' .. result.total_count)

    -- Calculate and display profit
    local profits = calculate_profit(result)
    if profits then
        local profit_text = ''
        if profits.vendor then
            profit_text = aux.color.green('VENDOR FLIP: +' .. money.to_string(profits.vendor.profit, true))
        elseif profits.market then
            profit_text = aux.color.green('MARKET FLIP: +' .. money.to_string(profits.market.profit, true) .. ' potential')
        end
        profit_label:SetText(profit_text)
    else
        if result.min_buyout then
            profit_label:SetText(aux.color.label.enabled('No profitable opportunities'))
        else
            profit_label:SetText('')
        end
    end

    -- Update auction listing
    local rows = {}
    if result.records then
        for i, record in result.records do
            if i <= 10 then  -- Show top 10
                tinsert(rows, {
                    cols = {
                        {value = record.aux_quantity},
                        {value = money.to_string(record.unit_buyout_price, true)},
                        {value = money.to_string(record.buyout_price, true)},
                        {value = al.time_left(record.duration)},
                    },
                    record = record,
                })
            end
        end
    end
    auction_listing:SetData(rows)
end
