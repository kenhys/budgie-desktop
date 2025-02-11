/*
 * This file is part of budgie-desktop
 *
 * Copyright © 2015-2022 Budgie Desktop Developers
 * Copyright 2014 Josh Klar <j@iv597.com> (original Budgie work, prior to Budgie 10)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

namespace Budgie {
	/** Spam apps */
	public const string ROOT_KEY_SPAM_APPS = "spam-apps";

	/** Spam categories */
	public const string ROOT_KEY_SPAM_CATEGORIES = "spam-categories";

	/**
	* Simple placeholder to use when there are no notifications
	*/
	public class NotificationPlaceholder : Gtk.Box {
		public NotificationPlaceholder() {
			Object(spacing: 6, orientation: Gtk.Orientation.VERTICAL);

			get_style_context().add_class("dim-label");
			var image = new Gtk.Image.from_icon_name("notification-alert-symbolic", Gtk.IconSize.DIALOG);
			image.pixel_size = 64;
			pack_start(image, false, false, 6);
			var label = new Gtk.Label("<big>%s</big>".printf(_("Nothing to see here")));
			label.use_markup = true;
			pack_start(label, false, false, 0);

			halign = Gtk.Align.CENTER;
			valign = Gtk.Align.CENTER;

			this.show_all();
		}
	}

	public const string NOTIFICATION_DBUS_NAME = "org.budgie_desktop.Notifications";
	public const string NOTIFICATION_DBUS_OBJECT_PATH = "/org/budgie_desktop/Notifications";

	[DBus (name="org.buddiesofbudgie.budgie.Dispatcher")]
	public interface Dispatcher : Object {
		public abstract bool notifications_paused { get; set; default = false; }

		public signal void NotificationAdded(
			string app_name,
			uint32 id,
			string app_icon,
			string summary,
			string body,
			string[] actions,
			HashTable<string, Variant> hints,
			int32 expire_timeout
		);

		public signal void NotificationClosed(uint32 id, string app_name, NotificationCloseReason reason);

		public abstract bool get_do_not_disturb() throws DBusError, IOError;
		public abstract void toggle_do_not_disturb() throws DBusError, IOError;
	}

	public class NotificationsView : Gtk.Box {
		private const string BUDGIE_PANEL_SCHEMA = "com.solus-project.budgie-panel";
		private const string APPLICATION_SCHEMA = "org.gnome.desktop.notifications.application";
		private const string APPLICATION_PREFIX = "/org/gnome/desktop/notifications/application";

		private HeaderWidget? header = null;
		private Gtk.Button button_mute;
		private Gtk.Button clear_notifications_button;
		private Gtk.ListBox? listbox;
		private Gtk.Image image_notifications_disabled = new Gtk.Image.from_icon_name("notification-disabled-symbolic", Gtk.IconSize.MENU);
		private Gtk.Image image_notifications_enabled = new Gtk.Image.from_icon_name("notification-alert-symbolic", Gtk.IconSize.MENU);

		private bool do_not_disturb { get; private set; default = false; }
		private bool performing_clear_all { get; private set; default = false; }

		private Dispatcher dispatcher { private get; private set; default = null; }
		private HashTable<uint32, Budgie.Notification> notifications { private get; private set; default = null; }
		private HashTable<string, NotificationGroup> notification_groups { private get; private set; default = null; }
		private Settings budgie_settings { private get; private set; default = null; }

		construct {
			this.budgie_settings = new Settings(BUDGIE_PANEL_SCHEMA);

			this.orientation = Gtk.Orientation.VERTICAL;
			this.spacing = 0;
			get_style_context().add_class("raven-notifications-view");

			clear_notifications_button = new Gtk.Button.from_icon_name("list-remove-all-symbolic", Gtk.IconSize.MENU);
			clear_notifications_button.relief = Gtk.ReliefStyle.NONE;
			clear_notifications_button.valign = Gtk.Align.CENTER;
			clear_notifications_button.no_show_all = true;
			clear_notifications_button.get_style_context().add_class("clear-all-notifications");

			button_mute = new Gtk.Button();
			button_mute.relief = Gtk.ReliefStyle.NONE;
			button_mute.valign = Gtk.Align.CENTER;
			button_mute.get_style_context().add_class("do-not-disturb");
			button_mute.set_image(image_notifications_enabled); // Ensure we start with an icon

			var control_buttons = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
			control_buttons.pack_start(button_mute, false, false, 0);
			control_buttons.pack_start(clear_notifications_button, false, false, 0);

			header = new HeaderWidget(_("No new notifications"), "notification-alert-symbolic", false, null, control_buttons);
			header.margin_top = 6;

			clear_notifications_button.clicked.connect(this.clear_all);
			button_mute.clicked.connect(this.do_not_disturb_toggle);

			pack_start(header, false, false, 0);

			notifications = new HashTable<uint32, Budgie.Notification>(direct_hash, direct_equal);
			notification_groups = new HashTable<string, NotificationGroup>(str_hash, str_equal);

			var scrolledwindow = new Gtk.ScrolledWindow(null, null);
			scrolledwindow.get_style_context().add_class("raven-background");
			scrolledwindow.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

			pack_start(scrolledwindow, true, true, 0);

			listbox = new Gtk.ListBox();
			listbox.set_selection_mode(Gtk.SelectionMode.NONE);
			var placeholder = new NotificationPlaceholder();
			listbox.set_placeholder(placeholder);
			scrolledwindow.add(listbox);

			show_all();
			update_child_count();

			Bus.get_proxy.begin<Dispatcher>(
				BusType.SESSION,
				NOTIFICATION_DBUS_NAME,
				NOTIFICATION_DBUS_OBJECT_PATH,
				0,
				null,
				on_dbus_get
			);
		}

		private void on_dbus_get(Object? o, AsyncResult? res) {
			try {
				this.dispatcher = Bus.get_proxy.end(res);
				this.dispatcher.NotificationAdded.connect(on_notification_added);
				this.dispatcher.NotificationClosed.connect(on_notification_closed);

				this.do_not_disturb = this.dispatcher.get_do_not_disturb();
				this.button_mute.set_image(this.do_not_disturb ? image_notifications_disabled : image_notifications_enabled);
			} catch (Error e) {
				critical("Unable to connect to notifications dispatcher: %s", e.message);
			}
		}

		private void on_notification_added(
			string app_name,
			uint32 id,
			string app_icon,
			string summary,
			string body,
			string[] actions,
			HashTable<string, Variant> hints,
			int32 expire_timeout
		) {
			var notification = new Budgie.Notification(
				id,
				app_name,
				app_icon,
				summary,
				body,
				actions,
				hints,
				expire_timeout
			);

			this.notifications[id] = notification;

			string settings_app_name = app_name;

			// If this notification has a desktop entry in the hints,
			// set the app name to get the settings for to it.
			if ("desktop-entry" in hints) {
				settings_app_name = hints.lookup("desktop-entry").get_string().replace(".", "-").down(); // This is necessary because Notifications application-children change . to - as well
			}

			Settings application_settings = new Settings.full(
				SettingsSchemaSource.get_default().lookup(APPLICATION_SCHEMA, true),
				null,
				"%s/%s/".printf(APPLICATION_PREFIX, settings_app_name)
			);

			// If popups aren't being shown, immediately call our close function to put
			// the notification in Raven.
			bool no_popup = this.do_not_disturb ||
							this.dispatcher.notifications_paused ||
							!application_settings.get_boolean("show-banners");

			if (no_popup) {
				on_notification_closed(id, app_name, NotificationCloseReason.EXPIRED);
			}
		}

		private void on_notification_closed(uint32 id, string app_name, NotificationCloseReason reason) {
			var notification = this.notifications[id];
			if (notification == null) {
				this.notifications.remove(id);
				return;
			}

			// We only care about expired notifications so we can add them to the
			// notifications view in Raven.
			if (reason == NotificationCloseReason.EXPIRED) {
				string[] spam_apps = budgie_settings.get_strv(Budgie.ROOT_KEY_SPAM_APPS);
				string[] spam_categories = budgie_settings.get_strv(Budgie.ROOT_KEY_SPAM_CATEGORIES);

				var app_id = (notification.app_id != null) ? notification.app_id : app_name;
				bool should_store = !(notification.category != null && notification.category in spam_categories) &&
									!(app_id != null && app_id in spam_apps);
				if (should_store) {
					// Get an icon to use for this application group
					string app_icon = ((app_name != "") && (app_name != null)) ? app_name : "applications-internet"; // Default app_icon to being the name of the app, or fallback

					if ((notification.image != null) && (notification.image.icon_name != null)) { // If we have an image set
						app_icon = notification.image.icon_name; // Use the icon specified in the image
					}

					app_icon = app_icon.down();

					if (app_icon == "image-invalid") {
						app_icon = "applications-internet";
					}

					var name = notification.app_name;
					if (notification.app_info != null) {
						if (notification.app_info.has_key("Icon")) {
							app_icon = notification.app_info.get_string("Icon");
						}
						if (notification.app_info.has_key("Name")) {
							name = notification.app_info.get_string("Name");
						}
					}

					// Look for an existing group. If one doesn't exist, create it
					var group = this.notification_groups.lookup(name);
					if (group == null) {
						group = new NotificationGroup(app_icon, name);
						this.listbox.add(group);

						group.dismissed_group.connect((name) => { // When we dismiss the group
							listbox.remove(group.get_parent()); // Remove this from the listbox

							/**
							* If we're not performing a clear all, steal this entry from notifications list and update our child count
							* Performing a steal seems to affect a .foreach call, so best to avoid this.
							*/
							if (!performing_clear_all) {
								notification_groups.steal(name); // Remove notifications group from list
								update_child_count();
							}

							Raven.get_instance().ReadNotifications(); // Update our counter
						});

						group.dismissed_notification.connect((id) => {
							update_child_count();
							Raven.get_instance().ReadNotifications(); // Update our counter
						});

						notification_groups.insert(name, group);
					}

					// Add the notification to the group, and notify Raven
					group.add_notification(id, notification);
					group.show_all();
					update_child_count();
					Raven.get_instance().UnreadNotifications();
				}
			}

			this.notifications.remove(id);
		}

		void update_child_count() {
			int len = 0;

			if (notification_groups.length != 0) {
				notification_groups.foreach((app_name, notification_group) => { // For each notifications list
					len += notification_group.count; // Add this notification group count
				});
			}

			string? text = null;
			if (len > 1) {
				text = _("%u unread notifications").printf(len);
			} else if (len == 1) {
				text = _("1 unread notification");
			} else {
				text = _("No unread notifications");
			}

			Raven.get_instance().set_notification_count(len);
			header.text = text;
			clear_notifications_button.set_visible((len >= 1)); // Only show clear notifications button if we actually have notifications
		}

		void clear_all() {
			performing_clear_all = true;

			notification_groups.foreach((app_name, notification_group) => {
				notification_group.dismiss_all();
			});

			notification_groups.steal_all(); // Ensure we're resetting notifications_list

			performing_clear_all = false;
			update_child_count();
			Raven.get_instance().ReadNotifications();
		}

		void do_not_disturb_toggle() {
			this.do_not_disturb = !this.do_not_disturb;
			this.button_mute.set_image(!this.do_not_disturb ? image_notifications_enabled : image_notifications_disabled);

			try {
				this.dispatcher.toggle_do_not_disturb();
			} catch (Error e) {
				warning("Unable to toggle Do Not Disturb: %s", e.message);
			}
		}
	}
}
