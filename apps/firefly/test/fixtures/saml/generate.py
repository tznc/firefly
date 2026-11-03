# Signs the SAML response fixtures with libxml2's exclusive canonicalization
# (through lxml), independently of Firefly's own, so the tests check our
# canonicalization against a reference implementation. Run from this
# directory: python3 generate.py (needs lxml and cryptography).
import base64
import hashlib

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from lxml import etree

DS = "http://www.w3.org/2000/09/xmldsig#"
EXC = "http://www.w3.org/2001/10/xml-exc-c14n#"
ALGS = {
    "sha256": ("http://www.w3.org/2001/04/xmlenc#sha256",
               "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256", hashes.SHA256()),
    "sha512": ("http://www.w3.org/2001/04/xmlenc#sha512",
               "http://www.w3.org/2001/04/xmldsig-more#rsa-sha512", hashes.SHA512()),
}

KEY = serialization.load_pem_private_key(open("idp_key.pem", "rb").read(), None)

ACS = "https://forum.example.com/auth/saml/acs"
SP = "https://forum.example.com/saml/metadata"
IDP = "https://idp.example.com/saml"


def signature(prefix, ref, prefixes, alg):
    digest_alg, sig_alg, _ = ALGS[alg]
    p = prefix + ":" if prefix else ""
    xmlns = f'xmlns:{prefix}="{DS}"' if prefix else f'xmlns="{DS}"'
    inclusive = (f'<ec:InclusiveNamespaces xmlns:ec="{EXC}" PrefixList="{prefixes}"/>'
                 if prefixes else "")
    return (f'<{p}Signature {xmlns}><{p}SignedInfo>'
            f'<{p}CanonicalizationMethod Algorithm="{EXC}"/>'
            f'<{p}SignatureMethod Algorithm="{sig_alg}"/>'
            f'<{p}Reference URI="#{ref}"><{p}Transforms>'
            f'<{p}Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>'
            f'<{p}Transform Algorithm="{EXC}">{inclusive}</{p}Transform>'
            f'</{p}Transforms><{p}DigestMethod Algorithm="{digest_alg}"/>'
            f'<{p}DigestValue></{p}DigestValue></{p}Reference></{p}SignedInfo>'
            f'<{p}SignatureValue></{p}SignatureValue></{p}Signature>')


def sign(root, element_id, prefixes, alg):
    element = root.xpath("//*[@ID=$id]", id=element_id)[0]
    sig = element.find(f"{{{DS}}}Signature")
    # The enveloped-signature transform drops the element but not the text
    # after it, which lxml keeps as the element's tail: park it before.
    copy = etree.fromstring(etree.tostring(root))
    copy_element = copy.xpath("//*[@ID=$id]", id=element_id)[0]
    copy_sig = copy_element.find(f"{{{DS}}}Signature")
    previous = copy_sig.getprevious()
    if previous is not None:
        previous.tail = (previous.tail or "") + (copy_sig.tail or "")
    else:
        copy_element.text = (copy_element.text or "") + (copy_sig.tail or "")
    copy_element.remove(copy_sig)
    data = etree.tostring(copy_element, method="c14n", exclusive=True,
                          inclusive_ns_prefixes=prefixes.split() or None)
    hash_name = alg
    sig.find(f".//{{{DS}}}DigestValue").text = base64.b64encode(
        hashlib.new(hash_name, data).digest()).decode()
    signed_info = sig.find(f"{{{DS}}}SignedInfo")
    signed = etree.tostring(signed_info, method="c14n", exclusive=True)
    value = KEY.sign(signed, padding.PKCS1v15(), ALGS[alg][2])
    sig.find(f"{{{DS}}}SignatureValue").text = base64.b64encode(value).decode()


def write(name, xml, signs):
    root = etree.fromstring(xml.encode())
    for element_id, prefixes, alg in signs:
        sign(root, element_id, prefixes, alg)
    open(name, "wb").write(etree.tostring(root, xml_declaration=True, encoding="UTF-8"))


def conditions(ns):
    return (f'<{ns}Conditions NotBefore="2026-11-03T11:59:00Z" NotOnOrAfter="2026-11-03T12:05:00Z">'
            f'<{ns}AudienceRestriction><{ns}Audience>{SP}</{ns}Audience></{ns}AudienceRestriction>'
            f'</{ns}Conditions>')


def subject(ns, name_id):
    return (f'<{ns}Subject><{ns}NameID Format="urn:oasis:names:tc:SAML:2.0:nameid-format:persistent">'
            f'{name_id}</{ns}NameID>'
            f'<{ns}SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">'
            f'<{ns}SubjectConfirmationData InResponseTo="_req_fixture" '
            f'NotOnOrAfter="2026-11-03T12:05:00Z" Recipient="{ACS}"/>'
            f'</{ns}SubjectConfirmation></{ns}Subject>')


# Okta-like: only the assertion is signed, with its own namespace
# declarations, and typed attribute values whose `xs` prefix is only
# used in an attribute value (hence the InclusiveNamespaces PrefixList).
okta_ns = "saml2:"
write("okta.xml", f'''<saml2p:Response xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" Destination="{ACS}" ID="id-okta-response" InResponseTo="_req_fixture" IssueInstant="2026-11-03T12:00:00Z" Version="2.0">
  <saml2:Issuer xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion">{IDP}</saml2:Issuer>
  <saml2p:Status><saml2p:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></saml2p:Status>
  <saml2:Assertion xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" xmlns:xs="http://www.w3.org/2001/XMLSchema" ID="id-okta-assertion" IssueInstant="2026-11-03T12:00:00Z" Version="2.0">
    <saml2:Issuer>{IDP}</saml2:Issuer>
    {signature("ds", "id-okta-assertion", "xs", "sha256")}
    {subject(okta_ns, "00u1okta")}
    {conditions(okta_ns)}
    <saml2:AuthnStatement AuthnInstant="2026-11-03T12:00:00Z" SessionIndex="id-okta-session"><saml2:AuthnContext><saml2:AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport</saml2:AuthnContextClassRef></saml2:AuthnContext></saml2:AuthnStatement>
    <saml2:AttributeStatement>
      <saml2:Attribute Name="email" NameFormat="urn:oasis:names:tc:SAML:2.0:attrname-format:basic"><saml2:AttributeValue xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="xs:string">ada@example.com</saml2:AttributeValue></saml2:Attribute>
      <saml2:Attribute Name="username"><saml2:AttributeValue xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="xs:string">ada</saml2:AttributeValue></saml2:Attribute>
      <saml2:Attribute Name="displayName"><saml2:AttributeValue>Ada &amp; Lovelace</saml2:AttributeValue></saml2:Attribute>
      <saml2:Attribute Name="groups"><saml2:AttributeValue>engineers</saml2:AttributeValue><saml2:AttributeValue>everyone</saml2:AttributeValue></saml2:Attribute>
    </saml2:AttributeStatement>
  </saml2:Assertion>
</saml2p:Response>''', [("id-okta-assertion", "xs", "sha256")])

# Azure AD / ADFS-like: unprefixed (default namespace) assertion and
# signature, URI-named attributes, the whole response signed instead.
claims = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims"
write("azure.xml", f'''<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="_azure-response" Version="2.0" IssueInstant="2026-11-03T12:00:00Z" Destination="{ACS}" InResponseTo="_req_fixture"><Issuer xmlns="urn:oasis:names:tc:SAML:2.0:assertion">{IDP}</Issuer>{signature(None, "_azure-response", "", "sha256")}<samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status><Assertion xmlns="urn:oasis:names:tc:SAML:2.0:assertion" ID="_azure-assertion" IssueInstant="2026-11-03T12:00:00Z" Version="2.0"><Issuer>{IDP}</Issuer>{subject("", "azure-object-id")}{conditions("")}<AttributeStatement><Attribute Name="{claims}/emailaddress"><AttributeValue>grace@example.com</AttributeValue></Attribute><Attribute Name="http://schemas.microsoft.com/identity/claims/displayname"><AttributeValue>Grace Hopper</AttributeValue></Attribute></AttributeStatement><AuthnStatement AuthnInstant="2026-11-03T12:00:00Z"><AuthnContext><AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:Password</AuthnContextClassRef></AuthnContext></AuthnStatement></Assertion></samlp:Response>''',
      [("_azure-response", "", "sha256")])

# Keycloak-like: the assertion's namespace is declared on the response (so
# the signed assertion inherits it) and both are signed, with SHA-512.
write("keycloak.xml", f'''<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" Destination="{ACS}" ID="ID_kc_response" InResponseTo="_req_fixture" IssueInstant="2026-11-03T12:00:00Z" Version="2.0"><saml:Issuer>{IDP}</saml:Issuer>{signature("dsig", "ID_kc_response", "", "sha512")}<samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status><saml:Assertion ID="ID_kc_assertion" IssueInstant="2026-11-03T12:00:00Z" Version="2.0"><saml:Issuer>{IDP}</saml:Issuer>{signature("dsig", "ID_kc_assertion", "", "sha512")}{subject("saml:", "f3b1c2d4-kc")}{conditions("saml:")}<saml:AuthnStatement AuthnInstant="2026-11-03T12:00:00Z"/><saml:AttributeStatement><saml:Attribute FriendlyName="email" Name="urn:oid:0.9.2342.19200300.100.1.3" NameFormat="urn:oasis:names:tc:SAML:2.0:attrname-format:uri"><saml:AttributeValue>linus@example.com</saml:AttributeValue></saml:Attribute></saml:AttributeStatement></saml:Assertion></samlp:Response>''',
      [("ID_kc_assertion", "", "sha512"), ("ID_kc_response", "", "sha512")])

# IdP metadata, as an IdP publishes it.
cert = "".join(l for l in open("idp_cert.pem").read().splitlines() if "CERTIFICATE" not in l)
open("idp_metadata.xml", "w").write(f'''<?xml version="1.0" encoding="UTF-8"?>
<md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="{IDP}">
  <md:IDPSSODescriptor WantAuthnRequestsSigned="false" protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
    <md:KeyDescriptor use="encryption"><ds:KeyInfo xmlns:ds="{DS}"><ds:X509Data><ds:X509Certificate>MIIBogus</ds:X509Certificate></ds:X509Data></ds:KeyInfo></md:KeyDescriptor>
    <md:KeyDescriptor use="signing"><ds:KeyInfo xmlns:ds="{DS}"><ds:X509Data><ds:X509Certificate>
{cert}
</ds:X509Certificate></ds:X509Data></ds:KeyInfo></md:KeyDescriptor>
    <md:NameIDFormat>urn:oasis:names:tc:SAML:2.0:nameid-format:persistent</md:NameIDFormat>
    <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="https://idp.example.com/saml/sso/post"/>
    <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="https://idp.example.com/saml/sso"/>
  </md:IDPSSODescriptor>
</md:EntityDescriptor>
''')
