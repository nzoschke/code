import re
from twisted.python import log, util

WHITESPACE = re.compile(r"\s")

def emit(self, eventDict={}):
    if eventDict["isError"] and "failure" in eventDict:
        text = ((eventDict.get('why') or 'Unhandled Error') + '\n' + eventDict['failure'].getTraceback() + "\n")
        util.untilConcludes(self.write, text)
        util.untilConcludes(self.flush)

        eventDict = {
            "message": [eventDict.get("why") or "Unhandled Error"],
            "system": eventDict["system"],
            "data": [("at", "error"), ("class", "CLASS")]
        }

    data  = eventDict.get("data") or []
    data += [("system", eventDict["system"]), ("message", eventDict["message"][0])]

    kvs = []
    for d in data:
        if isinstance(d, basestring):
            kvs.append(d)
        else:
            s = {
                "dict":     lambda v: "{..",
                "list":     lambda v: "[..",
                "NoneType": lambda v: "none",
                "float":    lambda v: "%.3f" % v,
                "datetime": lambda v: v.isoformat(),
                "date":     lambda v: v.isoformat(),
            }
            v = str(d[1])
            t = type(d[1]).__name__
            if t in s:
                v = s[t](d[1])

            if re.search(WHITESPACE, v):
                v = "\"%s\"" % v.replace("\n", " ")

            kvs.append("%s=%s" % (d[0], v))

    util.untilConcludes(self.write, " ".join(kvs) + "\n")
    util.untilConcludes(self.flush)
log.FileLogObserver.emit = emit
