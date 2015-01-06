#!/usr/bin/env python
"""
Communigate Pro settings data format

http://netwinder.osuosl.org/users/s/stalker/public_html/Data.html

Below is the formal syntax for the Dictionary and Array formats:

a-symbol   ::= A .. Z | a .. z | 0 .. 9
atom       ::= 1*a-symbol
s-symbol   ::= any printable symbol except " and \ |
                \\   |   \"   |  \r  | \n  | \e | \nnn
b-symbol   ::= a-symbol | + | / | =
string     ::= " 1*s-symbol " | atom
array      ::= ( [object [, object ...]] )
dictionary ::= { [string = object ; [string = object ; ...]] }
object     ::= string | array | dictionary

"""

import json
import re

tokens = ('ATOM', 'LPAR', 'RPAR', 'DATABLOCK', 'LCURLY', 'RCURLY', 'SEMICOLON', 'COMMA', 'EQUALS', 'STRING')

t_ATOM = r'[\w@.-]+'
t_LPAR = r'\('
t_RPAR = r'\)'
t_COMMA = r'\,'
t_LCURLY = r'\{'
t_RCURLY = r'\}'
t_SEMICOLON = r'\;'
t_EQUALS = r'\='

t_ignore = " \t\n\r"

def t_DATABLOCK(t):
    r'\[[^\]]*\]'
    t.value = re.sub(r'\s+', '', t.value[1:-1])
    return t

def t_STRING(t):
    r'("(\\"|[^"])*")|(\'(\\\'|[^\'])*\')'
    t.value = t.value[1:-1]
    t.value = t.value.replace('\\e', '\n')
    return t

def t_error(t):
    raise Exception("Illegal character '%s'" % t.value[0])
    
# Build the lexer
import ply.lex as lex
lex.lex(reflags=re.UNICODE)

# Parsing rules

def p_object(p):
    """object : string
              | array
              | dictionary
              | DATABLOCK"""
    p[0] = p[1]

def p_multistring(p):
    """multistring : STRING multistring
                   | STRING"""
    if len(p) == 3:
        p[0] = p[1] + p[2]
    else:
        p[0] = p[1]

def p_string(p):
    """string : multistring
              | ATOM"""
    p[0] = p[1]

def p_array(p):
    """array : LPAR array_items RPAR 
             | LPAR RPAR"""
    if len(p) == 4:
        p[0] = p[2]
    else:
        p[0] = ()

def p_array_items(p):
    """array_items : array_items COMMA object
                   | object"""
    if len(p) == 4:
        p[0] = p[1] + (p[3],)
    else:
        p[0] = (p[1],)

def p_dictionary(p):
    """dictionary : LCURLY dictionary_items RCURLY"""
    p[0] = dict(p[2])

def p_dictionary_items(p):
    """dictionary_items : dictionary_items dictionary_item
                        | dictionary_item"""
    if len(p) == 3:
        p[0] = p[1] + [p[2]]
    else:
        p[0] = [p[1]]

def p_dictionary_item(p):
    """dictionary_item : string EQUALS object SEMICOLON"""
    p[0] = (p[1], p[3])

def p_error(p):
    if p:
        raise Exception("Syntax error at '%s'" % p.value)
    else:
        raise Exception("Syntax error at EOF")

import ply.yacc as yacc
yacc.yacc(debug=0, write_tables=0)

# some tests

#print yacc.parse(u'{aap = hoe;}')
#print yacc.parse(u'{aap = hoe; bert = (a,b,ccc); cc = {aah = uuh; moeh = ();};}')
#print yacc.parse(u'banaan')
#print yacc.parse(u'"banaan"')
#print yacc.parse(u'(hop, "hop")')
#print yacc.parse(u'"woef"')
#print yacc.parse(u'waf')
#print yacc.parse(u'"waf is goed"')
#print yacc.parse(u'"\\"waf is goed\\""')
#print yacc.parse(u'''"'From' Name"''')
#print yacc.parse(u'"\\"ah\\""')
#print yacc.parse(u'"\\"oh ik haat } smurven #\\""')
#print yacc.parse(u'"oh ik haat } smurven #.."')
#print yacc.parse(u'''"'hoppeteetjes\\"'"''')
#print yacc.parse(u'''("Header Field",is,"X-Spam-Status:*ANY_BOUNCE_MESSAGE*")''')
#print yacc.parse(u'zarafa2@web.de')
#print yacc.parse(u'"einen"\r\n" der folgenden"')
#print yacc.parse(u'''[MIICDjCCAbigAwIBAgIEIWSoOjANBgkqhkiG9w0BAQQFADCBgTEiMCAGA1UEChMZU3RhbGtl
#DzANMAsGA1UdDwQEAwIA8DANBgkqhkiG9w0BAQQFAANBAGXap1oS/4cPn9TfjP/IEd6RDnek
#X95ejZBOFc5TKJmpxQ7llxcYSkv802N/qZ+wGvqfsLDsEXVUR0EDOdfTbyA=
#]''')
#print yacc.parse(u'{baviaan = [MIICDjCCAbigAwIBAgIEIWSoOjANBgkqhkiG9w0BAQQFADCBgTEiMCAGA1UEChMZU3RhbGtl];}')

def loads(s, encoding='utf-8'):
    if not isinstance(s, unicode):
        s = s.decode(encoding)
    return yacc.parse(s.strip())

def dumps(d):
    return json.dumps(d, indent=2)

if __name__ == '__main__':
    import sys
    print dumps(loads(file(sys.argv[1]).read()))
