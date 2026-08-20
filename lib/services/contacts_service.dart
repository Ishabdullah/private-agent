import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

/// Thrown by [ContactsService.searchContacts] when the Contacts permission
/// isn't granted, so callers can tell "permission denied" apart from
/// "genuinely no matching contact" — conflating the two previously showed
/// a misleading "contact not found" message for contacts that actually
/// exist, whenever permission simply hadn't been (re-)granted (e.g. after
/// a fresh install).
class ContactsPermissionDeniedException implements Exception {
  @override
  String toString() => 'Contacts permission not granted';
}

class ContactsService {
  /// Search contacts by name. Returns formatted results.
  ///
  /// Uses `permission_handler`'s `Permission.contacts` — the same check
  /// Settings/onboarding already use — rather than `flutter_contacts`'s own
  /// `requestPermission()`, so permission state is consistent across the
  /// app instead of two separate plugins tracking it independently.
  Future<List<Contact>> searchContacts(String query) async {
    var status = await Permission.contacts.status;
    if (!status.isGranted) {
      status = await Permission.contacts.request();
    }
    if (!status.isGranted) {
      throw ContactsPermissionDeniedException();
    }

    final contacts = await FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: false,
    );

    final lowerQuery = query.toLowerCase();
    return contacts.where((c) {
      return c.displayName.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Get phone number for a contact name. Returns the first match.
  Future<String?> getPhoneNumber(String contactName) async {
    final matches = await searchContacts(contactName);
    if (matches.isEmpty) return null;

    final contact = matches.first;
    if (contact.phones.isEmpty) return null;

    return contact.phones.first.number;
  }

  /// Format contact search results as readable text
  Future<String> searchAndFormat(String query) async {
    List<Contact> contacts;
    try {
      contacts = await searchContacts(query);
    } on ContactsPermissionDeniedException {
      return 'Contacts permission is required to search contacts. Grant '
          'it in Settings → App Permissions.';
    }

    if (contacts.isEmpty) {
      return 'No contacts found matching "$query".';
    }

    final buffer = StringBuffer('Found ${contacts.length} contact(s):\n');
    for (final contact in contacts.take(5)) {
      buffer.write('• ${contact.displayName}');
      if (contact.phones.isNotEmpty) {
        buffer.write(' - ${contact.phones.first.number}');
      }
      if (contact.emails.isNotEmpty) {
        buffer.write(' - ${contact.emails.first.address}');
      }
      buffer.writeln();
    }
    if (contacts.length > 5) {
      buffer.writeln('...and ${contacts.length - 5} more');
    }

    return buffer.toString();
  }
}
