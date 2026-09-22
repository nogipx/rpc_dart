// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// A test model: an address.
class Address implements IRpcSerializable {
  final String street;
  final String city;
  final String country;
  final int zipCode;

  Address({
    required this.street,
    required this.city,
    required this.country,
    required this.zipCode,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      'street': street,
      'city': city,
      'country': country,
      'zipCode': zipCode,
    };
  }

  factory Address.fromJson(Map<String, dynamic> json) {
    return Address(
      street: json['street'] as String,
      city: json['city'] as String,
      country: json['country'] as String,
      zipCode: json['zipCode'] as int,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Address &&
        other.street == street &&
        other.city == city &&
        other.country == country &&
        other.zipCode == zipCode;
  }

  @override
  int get hashCode =>
      street.hashCode ^ city.hashCode ^ country.hashCode ^ zipCode.hashCode;
}

// A test model: contact details.
class Contact implements IRpcSerializable {
  final String email;
  final String phone;

  Contact({required this.email, required this.phone});

  @override
  Map<String, dynamic> toJson() {
    return {'email': email, 'phone': phone};
  }

  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      email: json['email'] as String,
      phone: json['phone'] as String,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Contact && other.email == email && other.phone == phone;
  }

  @override
  int get hashCode => email.hashCode ^ phone.hashCode;
}

// A composite model, with nested objects.
class Person implements IRpcSerializable {
  final String name;
  final int age;
  final Address address;
  final Contact contact;
  final List<String> hobbies;
  final Map<String, int> scores;
  final RpcList<Address> alternativeAddresses;

  Person({
    required this.name,
    required this.age,
    required this.address,
    required this.contact,
    required this.hobbies,
    required this.scores,
    required this.alternativeAddresses,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'age': age,
      'address': address.toJson(),
      'contact': contact.toJson(),
      'hobbies': hobbies,
      'scores': scores,
      'alternativeAddresses': alternativeAddresses.toJson(),
    };
  }

  factory Person.fromJson(Map<String, dynamic> json) {
    // The nested objects.
    final addressJson = json['address'] as Map<String, dynamic>;
    final contactJson = json['contact'] as Map<String, dynamic>;
    final alternativeAddressesJson =
        json['alternativeAddresses'] as Map<String, dynamic>;

    return Person(
      name: json['name'] as String,
      age: json['age'] as int,
      address: Address.fromJson(addressJson),
      contact: Contact.fromJson(contactJson),
      hobbies: (json['hobbies'] as List<dynamic>).cast<String>(),
      scores: (json['scores'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, value as int),
      ),
      alternativeAddresses: RpcList.fromJson<Address>(
        (json) => Address.fromJson(json),
      )(alternativeAddressesJson),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Person &&
        other.name == name &&
        other.age == age &&
        other.address == address &&
        other.contact == contact &&
        listEquals(other.hobbies, hobbies) &&
        mapEquals(other.scores, scores) &&
        listEquals(
          other.alternativeAddresses.toList(),
          alternativeAddresses.toList(),
        );
  }

  @override
  int get hashCode =>
      name.hashCode ^
      age.hashCode ^
      address.hashCode ^
      contact.hashCode ^
      hobbies.hashCode ^
      scores.hashCode ^
      alternativeAddresses.hashCode;
}

// Helpers for comparing lists and maps.
bool listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || b[key] != a[key]) return false;
  }
  return true;
}

void main() {
  group('RpcCodec over composite objects', () {
    late RpcCodec<Person> codec;

    setUp(() {
      codec = RpcCodec<Person>(Person.fromJson);
    });

    test('a composite object survives a round trip', () {
      // An object with nested objects and collections in it.
      final person = Person(
        name: 'John Doe',
        age: 30,
        address: Address(
          street: '123 Main St',
          city: 'New York',
          country: 'USA',
          zipCode: 10001,
        ),
        contact: Contact(email: 'john@example.com', phone: '+1234567890'),
        hobbies: ['reading', 'hiking', 'coding'],
        scores: {'math': 95, 'science': 90, 'history': 85},
        alternativeAddresses: RpcList<Address>.from([
          Address(
            street: '456 Park Ave',
            city: 'Boston',
            country: 'USA',
            zipCode: 20001,
          ),
          Address(
            street: '789 Broadway',
            city: 'San Francisco',
            country: 'USA',
            zipCode: 30001,
          ),
        ]),
      );

      // Encode it.
      final bytes = codec.serialize(person);
      expect(bytes, isA<Uint8List>());
      expect(bytes.isNotEmpty, isTrue);

      // Decode it back.
      final deserializedPerson = codec.deserialize(bytes);

      // The top-level fields.
      expect(deserializedPerson, isA<Person>());
      expect(deserializedPerson.name, equals('John Doe'));
      expect(deserializedPerson.age, equals(30));

      // The nested Address.
      expect(deserializedPerson.address, isA<Address>());
      expect(deserializedPerson.address.street, equals('123 Main St'));
      expect(deserializedPerson.address.city, equals('New York'));
      expect(deserializedPerson.address.country, equals('USA'));
      expect(deserializedPerson.address.zipCode, equals(10001));

      // The nested Contact.
      expect(deserializedPerson.contact, isA<Contact>());
      expect(deserializedPerson.contact.email, equals('john@example.com'));
      expect(deserializedPerson.contact.phone, equals('+1234567890'));

      // The collections.
      expect(
        deserializedPerson.hobbies,
        equals(['reading', 'hiking', 'coding']),
      );
      expect(
        deserializedPerson.scores,
        equals({'math': 95, 'science': 90, 'history': 85}),
      );

      // An RpcList holding nested objects.
      expect(deserializedPerson.alternativeAddresses, isA<RpcList<Address>>());
      expect(deserializedPerson.alternativeAddresses.length, equals(2));
      expect(deserializedPerson.alternativeAddresses[0].city, equals('Boston'));
      expect(
        deserializedPerson.alternativeAddresses[1].city,
        equals('San Francisco'),
      );

      // And the whole object, compared at once.
      expect(deserializedPerson, equals(person));
    });

    test('an RpcList survives a round trip', () {
      // A list of Address objects.
      final addressList = RpcList<Address>.from([
        Address(
          street: '123 Main St',
          city: 'New York',
          country: 'USA',
          zipCode: 10001,
        ),
        Address(
          street: '456 Park Ave',
          city: 'Boston',
          country: 'USA',
          zipCode: 20001,
        ),
      ]);

      // A codec for RpcList<Address>.
      final listCodec = RpcCodec<RpcList<Address>>(
        RpcList.fromJson<Address>(Address.fromJson),
      );

      // Encode the list.
      final bytes = listCodec.serialize(addressList);
      expect(bytes, isA<Uint8List>());
      expect(bytes.isNotEmpty, isTrue);

      // Decode it back.
      final deserializedList = listCodec.deserialize(bytes);

      // The list came back intact.
      expect(deserializedList, isA<RpcList<Address>>());
      expect(deserializedList.length, equals(2));
      expect(deserializedList[0].city, equals('New York'));
      expect(deserializedList[1].city, equals('Boston'));

      // And element by element.
      expect(
        listEquals(deserializedList.toList(), addressList.toList()),
        isTrue,
      );
    });
  });
}
