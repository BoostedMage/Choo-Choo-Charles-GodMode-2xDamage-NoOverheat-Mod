-- Choo-Choo Charles v0.4.0 | compact, non-interactive status HUD.
-- Call every method from the game thread. Key bindings belong to main.lua.
-- Uses the UMG construction path confirmed to work in Jimmy's v0.2.0 log.
local HUD = {}

local function default_valid(object)
    if object == nil then return false end
    local ok, value = pcall(function() return object:IsValid() end)
    return ok and value == true
end

local function read_property(object, name)
    local ok, value = pcall(function() return object:GetPropertyValue(name) end)
    if ok and value ~= nil then return value end
    ok, value = pcall(function() return object[name] end)
    if ok then return value end
    return nil
end

local function identity(object)
    local ok, address = pcall(function() return object:GetAddress() end)
    if ok and address ~= nil then return tostring(address) end
    return tostring(object)
end

local function mode_text(mode)
    -- Readiness can never turn an OFF mode into ON.
    if type(mode) ~= "table" then return "OFF" end
    if mode.enabled ~= true then
        if mode.restoring == true then return "OFF (RESTORING)" end
        return "OFF"
    end
    if mode.ready ~= true then return "ON (NOT READY)" end
    return "ON"
end

function HUD.format_text(view)
    view = type(view) == "table" and view or {}
    local lines = {
        "F6 God Mode: " .. mode_text(view.player),
        "F7 Train God Mode: " .. mode_text(view.train),
        "F8 Double Damage: " .. mode_text(view.double),
        "F10 No Overheat: " .. mode_text(view.noheat),
        "[F9 Snapshot | F11 Hide HUD]",
    }
    if type(view.snapshot_notice) == "string" and view.snapshot_notice ~= "" then
        -- Keep a notice to one line so it cannot resize the status panel.
        lines[#lines + 1] = view.snapshot_notice:gsub("[\r\n]", " "):sub(1, 72)
    end
    return table.concat(lines, "\n")
end

function HUD.new(dependencies)
    assert(type(dependencies) == "table", "HUD dependencies are required")
    assert(type(dependencies.get_view) == "function", "HUD.get_view is required")
    assert(type(dependencies.get_controller) == "function", "HUD.get_controller is required")

    local valid = dependencies.is_valid or default_valid
    local read = dependencies.read_property or read_property
    local output = dependencies.log or function() end
    local self = {
        _visible = true,
        _closed = false,
        _widget = nil,
        _label = nil,
        _controller = nil,
        _controller_id = nil,
        _context_key = nil,
        _text = nil,
        _updates = 0,
        _retry_at = 0,
        _failures = 0,
        _last_error = nil,
    }

    local function log(message)
        pcall(output, message)
    end

    local function report_error(message)
        message = tostring(message)
        if message ~= self._last_error then
            self._last_error = message
            log("HUD: " .. message)
        end
    end

    local function dispose()
        if valid(self._widget) then
            -- Collapse first, so an unexpected removal error cannot leave a
            -- stale panel visible beside the replacement after map travel.
            pcall(function() self._widget:SetVisibility(1) end)
            local ok, err = pcall(function() self._widget:RemoveFromParent() end)
            if not ok then report_error("remove failed: " .. tostring(err)) end
        end
        self._widget, self._label, self._controller = nil, nil, nil
        self._controller_id, self._context_key, self._text = nil, nil, nil
    end

    local function context_key(controller)
        if type(dependencies.get_context_key) == "function" then
            local ok, key = pcall(dependencies.get_context_key, controller)
            if ok and key ~= nil then return tostring(key) end
        end
        -- A controller's full object path contains its owning map. This
        -- complements address comparison when the wrapper is re-created.
        local ok, name = pcall(function() return controller:GetFullName() end)
        if ok then return tostring(name) end
        return identity(controller)
    end

    local function create(controller, key, text)
        local created
        local ok, err = pcall(function()
            local user_class = StaticFindObject("/Script/UMG.UserWidget")
            local tree_class = StaticFindObject("/Script/UMG.WidgetTree")
            local canvas_class = StaticFindObject("/Script/UMG.CanvasPanel")
            local text_class = StaticFindObject("/Script/UMG.TextBlock")
            local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            if not (valid(user_class) and valid(tree_class) and valid(canvas_class)
                and valid(text_class) and valid(library)) then
                error("required UMG class is unavailable")
            end

            local widget = library:Create(controller, user_class, controller)
            if not valid(widget) then error("Create returned an invalid widget") end
            created = widget
            local tree = read(widget, "WidgetTree")
            if not valid(tree) then
                tree = StaticConstructObject(tree_class, widget)
                if not valid(tree) then error("WidgetTree construction failed") end
                widget.WidgetTree = tree
            end
            local canvas = StaticConstructObject(canvas_class, tree)
            if not valid(canvas) then error("CanvasPanel construction failed") end
            tree.RootWidget = canvas
            local label = StaticConstructObject(text_class, tree)
            if not valid(label) then error("TextBlock construction failed") end
            -- UE4.27 exposes Justification as a writable property. Set it
            -- before the Slate text widget is built; Right is enum value 2.
            label.Justification = 2
            local slot = canvas:AddChild(label)
            if not valid(slot) then error("CanvasPanel slot creation failed") end

            -- Anchor the slot's right edge to the canvas's right edge. The
            -- negative X inset stays consistent when the viewport resizes.
            slot:SetAnchors({Minimum = {X = 1, Y = 0}, Maximum = {X = 1, Y = 0}})
            slot:SetAlignment({X = 1, Y = 0})
            slot:SetPosition({X = -12, Y = 10})
            slot:SetSize({X = 680, Y = 180})
            label:SetText(FText(text))
            pcall(function() label:SetAutoWrapText(false) end)
            pcall(function()
                label:SetColorAndOpacity({SpecifiedColor = {R = 0.88, G = 0.95, B = 1, A = 1}, ColorUseRule = 0})
            end)
            pcall(function() label:SetShadowOffset({X = 1, Y = 1}) end)
            -- Scale about the upper-right corner so shrinking the wide slot
            -- does not move its visible text away from the right/top inset.
            label:SetRenderTransformPivot({X = 1, Y = 0})
            pcall(function() label:SetRenderScale({X = 0.65, Y = 0.65}) end)
            label:SetVisibility(3) -- HitTestInvisible: never captures gameplay input.
            widget:AddToViewport(990)
            widget:SetVisibility(3)

            self._widget, self._label = widget, label
            self._controller = controller
            self._controller_id = identity(controller)
            self._context_key, self._text = key, text
            self._failures, self._last_error = 0, nil
            log("HUD ready. F6/F7/F8/F10 toggle modes; F9 snapshot; F11 hide/show.")
        end)

        if not ok then
            if valid(created) then
                pcall(function() created:SetVisibility(1) end)
                pcall(function() created:RemoveFromParent() end)
            end
            self._failures = self._failures + 1
            self._retry_at = self._updates + math.min(50, 5 * self._failures)
            report_error("creation failed: " .. tostring(err))
        end
        return ok
    end

    function self:update()
        if self._closed then return false end
        self._updates = self._updates + 1
        local got_controller, controller = pcall(dependencies.get_controller)
        if not got_controller or not valid(controller) then
            if self._widget ~= nil then dispose() end
            return false
        end
        local key = context_key(controller)
        if self._widget ~= nil and (not valid(self._widget) or not valid(self._label)
            or not valid(self._controller) or self._controller_id ~= identity(controller)
            or self._context_key ~= key) then
            dispose()
            self._retry_at = self._updates
        end

        if not self._visible then
            if valid(self._widget) then pcall(function() self._widget:SetVisibility(1) end) end
            return false
        end
        local got_view, view = pcall(dependencies.get_view)
        if not got_view then
            report_error("status unavailable: " .. tostring(view))
            -- Retire stale ON labels if the state provider fails.
            dispose()
            return false
        end
        local text = HUD.format_text(view)
        if not valid(self._widget) then
            if self._updates < self._retry_at then return false end
            return create(controller, key, text)
        end
        local ok, err = pcall(function()
            if self._text ~= text then
                self._label:SetText(FText(text))
                self._text = text -- Commit only after a successful SetText call.
            end
            self._widget:SetVisibility(3)
        end)
        if not ok then
            report_error("update failed: " .. tostring(err))
            dispose()
            self._retry_at = self._updates + 5
            return false
        end
        return true
    end

    function self:set_visible(visible)
        self._visible = visible == true
        if not self._visible and valid(self._widget) then
            pcall(function() self._widget:SetVisibility(1) end)
        end
        return self:update()
    end

    function self:is_visible()
        return self._visible and not self._closed
    end

    function self:is_drawn()
        return self:is_visible() and valid(self._widget) and valid(self._label)
    end

    function self:reset()
        dispose()
        self._retry_at, self._failures, self._last_error = 0, 0, nil
    end

    function self:shutdown()
        self._closed = true
        dispose()
    end

    return self
end

return HUD
