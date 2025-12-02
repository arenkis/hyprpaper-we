import gi
import json
import subprocess

gi.require_version('Gtk', '4.0')
gi.require_version('WebKit', '6.0')
gi.require_version('Gtk4LayerShell', '1.0')

from gi.repository import Gtk, WebKit, Gtk4LayerShell, Gdk, Gio
import sys
import os





def get_monitor_info(monitor_name):
    """Get monitor geometry from hyprctl"""
    try:
        result = subprocess.run(['hyprctl', 'monitors', '-j'], 
                              capture_output=True, text=True, check=True)
        monitors = json.loads(result.stdout)
        
        for monitor in monitors:
            if monitor['name'] == monitor_name:
                return {
                    'x': monitor['x'],
                    'y': monitor['y'],
                    'width': monitor['width'],
                    'height': monitor['height']
                }
    except Exception as e:
        print(f"Error getting monitor info: {e}", file=sys.stderr)
    return None

class WebWallpaperWindow(Gtk.ApplicationWindow):
    def __init__(self, monitor_name=None, *args, **kwargs):
        super().__init__(*args, **kwargs)
        
        self.monitor_name = monitor_name
        self.webview = WebKit.WebView()
        self.set_child(self.webview)
        
        # Configure layer shell for background wallpaper display
        Gtk4LayerShell.init_for_window(self)
        Gtk4LayerShell.set_layer(self, Gtk4LayerShell.Layer.BACKGROUND)
        Gtk4LayerShell.set_keyboard_mode(self, Gtk4LayerShell.KeyboardMode.NONE)
        
        # If a specific monitor is provided, set up the window for that monitor
        if monitor_name:
            monitor_info = get_monitor_info(monitor_name)
            if monitor_info:
                # Set margins to position the window on the specific monitor
                Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.TOP, False)
                Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.BOTTOM, False)
                Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.LEFT, False)
                Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.RIGHT, False)
                
                # Set specific size and position
                self.set_default_size(monitor_info['width'], monitor_info['height'])
                
                # Use margins to position on specific monitor
                Gtk4LayerShell.set_margin(self, Gtk4LayerShell.Edge.LEFT, monitor_info['x'])
                Gtk4LayerShell.set_margin(self, Gtk4LayerShell.Edge.TOP, monitor_info['y'])
            else:
                print(f"Warning: Could not get info for monitor {monitor_name}, using default anchoring", file=sys.stderr)
                # Fallback to default full-screen anchoring
                Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.TOP, True)
                Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.BOTTOM, True)
                Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.LEFT, True)
                Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.RIGHT, True)
        else:
            # No specific monitor - anchor to all edges (spans all monitors)
            Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.TOP, True)
            Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.BOTTOM, True)
            Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.LEFT, True)
            Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.RIGHT, True)





    def load_uri(self, uri):
        self.webview.load_uri(uri)

class WebWallpaperApp(Gtk.Application):
    def __init__(self, uri, monitor_name=None, *args, **kwargs):
        super().__init__(*args, application_id="dev.gemini.hyprpaperwe.simple.v2", **kwargs)
        self.uri = uri
        self.monitor_name = monitor_name
        self.win = None

    def do_activate(self):
        if not self.win:
            self.win = WebWallpaperWindow(monitor_name=self.monitor_name, application=self)
        self.win.load_uri(self.uri)
        self.win.present()

if __name__ == "__main__":
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        print("Usage: web_viewer.py <html_path> [monitor_name]", file=sys.stderr)
        sys.exit(1)
    
    uri = Gio.File.new_for_path(sys.argv[1]).get_uri()
    monitor_name = sys.argv[2] if len(sys.argv) == 3 else None
    
    app = WebWallpaperApp(uri, monitor_name)
    app.run(None)



