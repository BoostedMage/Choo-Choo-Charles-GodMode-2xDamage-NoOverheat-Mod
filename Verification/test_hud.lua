-- Regression tests for status labels and UMG lifecycle, with Unreal objects mocked.
local scripts = os.getenv('CCC_MOD_SCRIPTS') or './Mod/ChooChooCharles_GodMode/Scripts'
local HUD = dofile(scripts .. '/hud.lua')
local created, removed, labels, slots = {}, {}, {}, {}
local fail_text, fail_view = false, false
local serial = 0
local function object(kind)
    serial = serial + 1
    local value = {kind = kind, live = true, id = serial}
    function value:IsValid() return self.live end
    function value:GetAddress() return self.id end
    function value:GetFullName() return self.kind .. ':' .. self.id end
    function value:GetPropertyValue(name) return rawget(self, name) end
    return value
end
local classes = {}
for _, name in ipairs({'UserWidget', 'WidgetTree', 'CanvasPanel', 'TextBlock'}) do
    classes['/Script/UMG.' .. name] = object(name)
end
local library = object('WidgetBlueprintLibrary')
function library:Create(controller)
    local widget = object('UserWidget')
    widget.controller = controller
    function widget:SetVisibility(value) self.visibility = value end
    function widget:AddToViewport() self.in_viewport = true end
    function widget:RemoveFromParent()
        self.in_viewport = false
        removed[#removed + 1] = self
    end
    created[#created + 1] = widget
    return widget
end
classes['/Script/UMG.Default__WidgetBlueprintLibrary'] = library
function StaticFindObject(name) return classes[name] end
function FText(text) return text end
function StaticConstructObject(class, outer)
    local value = object(class.kind)
    value.outer = outer
    if class.kind == 'CanvasPanel' then
        function value:AddChild(label)
            assert(label.Justification == 2, 'right justification is set before adding the text widget')
            self.label = label
            local slot = object('CanvasPanelSlot')
            for _, name in ipairs({'SetAnchors','SetAlignment','SetPosition','SetSize'}) do
                slot[name] = function(self, setting) self[name .. 'value'] = setting end
            end
            slots[#slots + 1] = slot
            return slot
        end
    elseif class.kind == 'TextBlock' then
        labels[#labels + 1] = value
        function value:SetText(text)
            if fail_text then error('injected SetText failure') end
            self.text = text
        end
        -- No SetJustification mock: UE4.27 exposes the reflected property.
        for _, name in ipairs({'SetAutoWrapText','SetColorAndOpacity',
                              'SetShadowOffset','SetRenderTransformPivot','SetRenderScale','SetVisibility'}) do
            value[name] = function(self, setting) self[name .. 'value'] = setting end
        end
    end
    return value
end
local view = {
    player = {enabled=true, ready=true},
    train = {enabled=true, ready=true},
    double = {enabled=true, ready=true},
    noheat = {enabled=true, ready=true},
}
local controller = object('Controller')
local map = 'island'
local logs = {}
local hud = HUD.new({
    log = function(message) logs[#logs+1] = message end,
    get_view = function() if fail_view then error('injected provider failure') end; return view end,
    get_controller = function() return controller end,
    get_context_key = function() return map end,
})
local expected = 'F6 God Mode: ON\nF7 Train God Mode: ON\nF8 Double Damage: ON\nF10 No Overheat: ON\n[F9 Snapshot | F11 Hide HUD]'
assert(HUD.format_text(view) == expected, 'exact hotkey labels')
assert(hud:update() == true and hud:is_drawn(), 'first creation')
assert(#created == 1 and labels[1].text == expected, 'one widget with expected text')
assert(created[1].visibility == 3 and labels[1].SetVisibilityvalue == 3, 'HUD never captures input')
local anchors = slots[1].SetAnchorsvalue
local alignment = slots[1].SetAlignmentvalue
local position = slots[1].SetPositionvalue
local size = slots[1].SetSizevalue
local pivot = labels[1].SetRenderTransformPivotvalue
local scale = labels[1].SetRenderScalevalue
assert(anchors.Minimum.X == 1 and anchors.Maximum.X == 1
    and anchors.Minimum.Y == 0 and anchors.Maximum.Y == 0, 'fixed upper-right canvas anchor')
assert(alignment.X == 1 and alignment.Y == 0, 'slot aligned by its upper-right corner')
assert(position.X == -12 and position.Y == 10, 'right inset is negative; top inset is positive')
assert(pivot.X == 1 and pivot.Y == 0, 'render scaling pivots at the upper-right corner')
assert(scale.X == 0.65 and scale.Y == 0.65 and size.X == 680 and size.Y == 180, 'compact text size retained')
assert(labels[1].Justification == 2 and labels[1].SetAutoWrapTextvalue == false, 'rows align to the right without wrapping')
for _, viewport in ipairs({{1280, 720}, {1920, 1080}, {3440, 1440}}) do
    -- Transform the slot's right/top edges as Slate does for a scale about a
    -- normalized pivot. This catches the default-center pivot's extra inset.
    local left = viewport[1] * anchors.Minimum.X + position.X - size.X * alignment.X
    local top = viewport[2] * anchors.Minimum.Y + position.Y - size.Y * alignment.Y
    local right = left + size.X * pivot.X + size.X * (1 - pivot.X) * scale.X
    local rendered_top = top + size.Y * pivot.Y - size.Y * pivot.Y * scale.Y
    assert(math.abs(right - (viewport[1] - 12)) < 0.001, 'scaled text right edge stays at 12-unit inset')
    assert(math.abs(rendered_top - 10) < 0.001, 'scaled text top stays at 10-unit inset')
end
hud:update(); hud:update()
assert(#created == 1, 'polling must not duplicate HUD')

view.player.enabled = false
hud:update()
assert(labels[1].text:find('F6 God Mode: OFF',1,true), 'F6 OFF is always OFF even if ready=true')
view.train.ready = false
hud:update()
assert(labels[1].text:find('F7 Train God Mode: ON (NOT READY)',1,true), 'unready backend is explicit')
view.train.enabled = false
hud:update()
assert(labels[1].text:find('F7 Train God Mode: OFF',1,true), 'disabled unready mode stays OFF')
assert(not labels[1].text:find('Ctrl',1,true), 'no modifier-key labels remain')

view.noheat.enabled = false
hud:update()
assert(labels[1].text:find('F10 No Overheat: OFF',1,true), 'F10 OFF is OFF even if ready=true')
assert(labels[1].text:find('F8 Double Damage: ON',1,true), 'F10 does not change another mode label')
view.noheat.ready = false
hud:update()
assert(labels[1].text:find('F10 No Overheat: OFF\n',1,true), 'disabled unready no-overheat mode remains OFF')
view.noheat.enabled = true
hud:update()
assert(labels[1].text:find('F10 No Overheat: ON (NOT READY)',1,true), 'unready no-overheat backend is explicit')
view.noheat.ready = true
hud:update()
assert(labels[1].text:find('F10 No Overheat: ON\n',1,true), 'ready no-overheat mode returns to ON')

hud:set_visible(false)
assert(not hud:is_drawn() and not hud:is_visible() and created[1].visibility == 1, 'F11 immediately hides')
view.double.enabled = false
view.noheat.enabled = false
hud:update()
assert(#created == 1, 'hidden HUD does not allocate')
hud:set_visible(true)
assert(hud:is_drawn() and created[1].visibility == 3, 'F11 shows same widget')
assert(labels[1].text:find('F8 Double Damage: OFF',1,true), 'show refreshes hidden toggle changes')
assert(labels[1].text:find('F10 No Overheat: OFF',1,true), 'show refreshes the hidden F10 toggle')

controller = object('Controller') -- The old controller is deliberately still valid.
hud:update()
assert(#created == 2 and #removed == 1 and not created[1].in_viewport, 'controller replacement removes old HUD')
map = 'intro_cutscene'
hud:update()
assert(#created == 3 and #removed == 2, 'map context change recreates HUD')
view.snapshot_notice = 'Snapshot saved\nnow'
hud:update()
assert(labels[#labels].text:find('Snapshot saved now',1,true), 'snapshot notice is limited to one line')

fail_view = true
hud:update()
assert(not hud:is_drawn() and not created[3].in_viewport, 'provider failure cannot leave stale ON labels')
fail_view = false
hud:update()
assert(hud:is_drawn(), 'provider recovery rebuilds HUD')

hud:reset()
fail_text = true
local count_before = #created
hud:update()
assert(#created == count_before+1 and not created[#created].in_viewport, 'failed creation disposes partial widget')
assert(not hud:is_drawn(), 'failed text creation is not reported visible')
fail_text = false
for _=1,8 do hud:update() end
assert(hud:is_drawn(), 'creation retries recover')

controller.live = false
hud:update()
assert(not hud:is_drawn() and not created[#created].in_viewport, 'controller unload removes panel')
controller = object('Controller')
hud:update()
assert(hud:is_drawn(), 'new controller can rebuild panel')
hud:shutdown()
local total = #created
hud:set_visible(true); hud:update()
assert(#created == total and not hud:is_drawn(), 'shutdown never recreates panel')
print('HUD tests PASS: top-right anchors/alignment/pivot at three viewport sizes; exact labels; F10 OFF/readiness; plain keys; F11 hide/show; map/controller cleanup; failure recovery.')
