import asyncio
import json
import os
import sys

from dbus_next import Message, MessageType, Variant
from dbus_next.aio import MessageBus
from dbus_next.constants import BusType, RequestNameReply


REGISTRAR_BUS = "com.canonical.AppMenu.Registrar"
REGISTRAR_PATH = "/com/canonical/AppMenu/Registrar"
REGISTRAR_INTERFACE = "com.canonical.AppMenu.Registrar"
MENU_INTERFACE = "com.canonical.dbusmenu"
MENU_PROPERTIES = [
    "children-display",
    "enabled",
    "icon-name",
    "label",
    "toggle-state",
    "toggle-type",
    "type",
    "visible",
]


def unpack(value):
    return value.value if isinstance(value, Variant) else value


def clean_label(label):
    result = []
    index = 0
    while index < len(label):
        if label[index] != "_":
            result.append(label[index])
        elif index + 1 < len(label) and label[index + 1] == "_":
            result.append("_")
            index += 1
        index += 1
    return "".join(result)


def parse_layout(value):
    value = unpack(value)
    item_id, raw_properties, raw_children = value
    properties = {name: unpack(item) for name, item in raw_properties.items()}
    return {
        "id": item_id,
        "properties": properties,
        "children": [parse_layout(child) for child in raw_children],
    }


class AppMenuBridge:
    def __init__(self):
        self.bus = None
        self.registrations = {}
        self.active_pid = 0
        self.selected = None
        self.headings = []
        self.sequence = 0
        self.last_menus = None

    async def start(self):
        self.bus = await MessageBus(bus_type=BusType.SESSION).connect()
        reply = await self.bus.request_name(REGISTRAR_BUS)
        owned_replies = (
            RequestNameReply.PRIMARY_OWNER,
            RequestNameReply.ALREADY_OWNER,
        )
        if reply not in owned_replies:
            raise RuntimeError(f"{REGISTRAR_BUS} is already owned")
        self.bus.add_message_handler(self.handle_message)
        await self.bus.call(
            Message(
                destination="org.freedesktop.DBus",
                path="/org/freedesktop/DBus",
                interface="org.freedesktop.DBus",
                member="AddMatch",
                signature="s",
                body=[
                    "type='signal',interface='org.freedesktop.DBus',"
                    "member='NameOwnerChanged'"
                ],
            )
        )
        asyncio.get_running_loop().add_reader(
            sys.stdin.fileno(), self.read_command
        )
        self.publish_menus([])

    def handle_message(self, message):
        if (
            message.message_type == MessageType.SIGNAL
            and message.interface == "org.freedesktop.DBus"
            and message.member == "NameOwnerChanged"
        ):
            name, old_owner, new_owner = message.body
            if name.startswith(":") and old_owner and not new_owner:
                self.remove_service(name)
            return False

        if (
            message.message_type == MessageType.METHOD_CALL
            and message.path == REGISTRAR_PATH
            and message.interface == "org.freedesktop.DBus.Introspectable"
            and message.member == "Introspect"
        ):
            return Message.new_method_return(
                message, "s", [self.introspection_xml()]
            )

        if (
            message.message_type != MessageType.METHOD_CALL
            or message.path != REGISTRAR_PATH
            or message.interface != REGISTRAR_INTERFACE
        ):
            return False

        if message.member == "RegisterWindow" and len(message.body) == 2:
            window_id, path = message.body
            asyncio.create_task(
                self.register_window(window_id, message.sender, path)
            )
            self.emit_signal(
                "WindowRegistered", "uso", [window_id, message.sender, path]
            )
            return Message.new_method_return(message)
        if message.member == "UnregisterWindow" and len(message.body) == 1:
            window_id = message.body[0]
            self.registrations.pop(window_id, None)
            asyncio.create_task(self.select_menu())
            self.emit_signal("WindowUnregistered", "u", [window_id])
            return Message.new_method_return(message)
        if message.member == "GetMenuForWindow" and len(message.body) == 1:
            registration = self.registrations.get(message.body[0])
            if registration:
                return Message.new_method_return(
                    message,
                    "so",
                    [registration["service"], registration["path"]],
                )
            return Message.new_method_return(message, "so", ["", "/"])
        return Message.new_error(
            message,
            "org.freedesktop.DBus.Error.UnknownMethod",
            "Unknown method",
        )

    async def register_window(self, window_id, service, path):
        pid = await self.service_pid(service)
        self.sequence += 1
        self.registrations[window_id] = {
            "service": service,
            "path": path,
            "pid": pid,
            "sequence": self.sequence,
        }
        await self.select_menu()

    async def service_pid(self, service):
        reply = await self.bus.call(
            Message(
                destination="org.freedesktop.DBus",
                path="/org/freedesktop/DBus",
                interface="org.freedesktop.DBus",
                member="GetConnectionUnixProcessID",
                signature="s",
                body=[service],
            )
        )
        if reply.message_type == MessageType.ERROR or not reply.body:
            return 0
        return int(reply.body[0])

    def remove_service(self, service):
        self.registrations = {
            window_id: registration
            for window_id, registration in self.registrations.items()
            if registration["service"] != service
        }
        asyncio.create_task(self.select_menu())

    def emit_signal(self, member, signature, body):
        self.bus.send(
            Message(
                message_type=MessageType.SIGNAL,
                path=REGISTRAR_PATH,
                interface=REGISTRAR_INTERFACE,
                member=member,
                signature=signature,
                body=body,
            )
        )

    def read_command(self):
        line = sys.stdin.readline()
        if not line:
            asyncio.get_running_loop().remove_reader(sys.stdin.fileno())
            return
        try:
            command = json.loads(line)
        except (TypeError, ValueError):
            return
        if "focus" in command:
            pid = int(command["focus"] or 0)
            if pid != os.getpid():
                self.active_pid = pid
                asyncio.create_task(self.select_menu())
        elif "show" in command:
            asyncio.create_task(self.show_menu(int(command["show"])))
        elif "activate" in command:
            asyncio.create_task(self.activate(int(command["activate"])))

    async def select_menu(self):
        matches = [
            registration
            for registration in self.registrations.values()
            if registration["pid"] == self.active_pid
        ]
        selected = max(
            matches, key=lambda item: item["sequence"], default=None
        )
        self.selected = selected
        if not selected:
            self.headings = []
            self.publish_menus([])
            return
        root = await self.get_layout(0, 1)
        if root is None:
            self.headings = []
            self.publish_menus([])
            return

        menus = []
        self.headings = []
        for child in root["children"]:
            properties = child["properties"]
            if not properties.get("visible", True):
                continue
            label = clean_label(properties.get("label", ""))
            if not label:
                continue
            self.headings.append(child["id"])
            menus.append(
                {"label": label, "enabled": properties.get("enabled", True)}
            )
        self.publish_menus(menus)

    async def get_layout(self, parent_id, depth):
        if not self.selected:
            return None
        reply = await self.bus.call(
            Message(
                destination=self.selected["service"],
                path=self.selected["path"],
                interface=MENU_INTERFACE,
                member="GetLayout",
                signature="iias",
                body=[parent_id, depth, MENU_PROPERTIES],
            )
        )
        if reply.message_type == MessageType.ERROR or len(reply.body) < 2:
            return None
        return parse_layout(reply.body[1])

    async def about_to_show(self, item_id):
        if not self.selected:
            return
        await self.bus.call(
            Message(
                destination=self.selected["service"],
                path=self.selected["path"],
                interface=MENU_INTERFACE,
                member="AboutToShow",
                signature="i",
                body=[item_id],
            )
        )

    async def show_menu(self, index):
        if index < 0 or index >= len(self.headings):
            return
        item_id = self.headings[index]
        await self.about_to_show(item_id)
        layout = await self.get_layout(item_id, -1)
        if layout is None:
            return
        self.publish(
            {
                "popup": {
                    "heading": index,
                    "items": self.menu_items(layout["children"]),
                }
            }
        )

    def menu_items(self, items):
        result = []
        for item in items:
            properties = item["properties"]
            if not properties.get("visible", True):
                continue
            if properties.get("type") == "separator":
                result.append({"separator": True})
                continue
            label = clean_label(properties.get("label", ""))
            if not label:
                continue
            result.append(
                {
                    "id": item["id"],
                    "label": label,
                    "enabled": properties.get("enabled", True),
                    "checked": properties.get("toggle-state", 0) > 0,
                    "toggle": bool(properties.get("toggle-type")),
                    "children": self.menu_items(item["children"]),
                }
            )
        return result

    async def activate(self, item_id):
        if not self.selected:
            return
        self.bus.send(
            Message(
                destination=self.selected["service"],
                path=self.selected["path"],
                interface=MENU_INTERFACE,
                member="Event",
                signature="isvu",
                body=[item_id, "clicked", Variant("s", ""), 0],
            )
        )

    def publish_menus(self, menus):
        if menus == self.last_menus:
            return
        self.last_menus = menus
        self.publish({"menus": menus})

    @staticmethod
    def publish(message):
        print(json.dumps(message, separators=(",", ":")), flush=True)

    @staticmethod
    def introspection_xml():
        return """<node>
<interface name="com.canonical.AppMenu.Registrar">
  <method name="RegisterWindow">
    <arg name="windowId" type="u" direction="in"/>
    <arg name="menuObjectPath" type="o" direction="in"/>
  </method>
  <method name="UnregisterWindow">
    <arg name="windowId" type="u" direction="in"/>
  </method>
  <method name="GetMenuForWindow">
    <arg name="windowId" type="u" direction="in"/>
    <arg name="service" type="s" direction="out"/>
    <arg name="menuObjectPath" type="o" direction="out"/>
  </method>
  <signal name="WindowRegistered">
    <arg name="windowId" type="u"/>
    <arg name="service" type="s"/>
    <arg name="menuObjectPath" type="o"/>
  </signal>
  <signal name="WindowUnregistered">
    <arg name="windowId" type="u"/>
  </signal>
</interface>
</node>"""


async def main():
    bridge = AppMenuBridge()
    await bridge.start()
    await asyncio.get_running_loop().create_future()


asyncio.run(main())
