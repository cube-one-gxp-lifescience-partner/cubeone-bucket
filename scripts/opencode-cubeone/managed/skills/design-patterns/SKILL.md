---
name: design-patterns
description: Design-pattern guide distilled from "Head First Design Patterns". Use when designing, extending or refactoring code — new classes/modules, extension points, integrations with external systems or data sources, or code that repeatedly branches on type, mode or status. Applies patterns only where they make the code simpler.
---

# Design Patterns — Guide for AI Coding Agents

Distilled from *Head First Design Patterns* (Freeman & Robson, 2nd ed., O'Reilly 2020) and turned into operational rules, plus a few practical heuristics for modern languages and AI-assisted coding.

**Goal:** apply proven patterns where they fit naturally and make change easier — nothing more. Avoid both failure modes:
- **Over-engineering:** patterns, layers and interfaces without a present need.
- **Under-engineering:** missing an obvious pattern, e.g. the same type `switch` in five places or vendor types leaking into domain code (§10).

The book's ideal is the "Zen mind": the question is not "where can I use a pattern?" but "what is the simplest design that solves this?" — patterns show up only where they fit naturally.

**How to use this file:** §1 applies to every change. Run §2 before adding any abstraction. §3–§10 are lookup material. §11 defines how to work and report design decisions. §12 summarizes the book.

---

## 1. Core rules

1. **Simplest solution first.** Write the simplest code that is correct, readable and testable for the *current* requirements. A pattern is a tool for a concrete problem, never a goal.
2. **No pattern without a trigger.** Introduce a pattern only if a signal from §4 is present in the code or in a stated requirement *now*. Hypothetical future change is not a reason (YAGNI).
3. **Follow the codebase.** First detect which patterns, frameworks and conventions the project already uses (DI container, event system, middleware, plugin registry, ORM features) and extend them. Consistency beats textbook purity; never add a second mechanism for the same job.
4. **Lightest form wins.** Function/lambda → map of functions → interface + classes → class hierarchy. Use language features before class ceremony (§9).
5. **Composition over inheritance.** Inherit only for true *is-a* relationships, never just to reuse code. In your own code, prefer at most one level of subclasses below an abstraction; framework-mandated inheritance is fine.
6. **Abstractions where they pay.** Program against interfaces — but create an interface/protocol only if (a) ≥ 2 implementations exist now, or (b) it wraps a system boundary (external API, database, file system, clock, randomness, network) that tests must replace.
7. **Shared vocabulary.** Name roles after the pattern (`ShippingCostStrategy`, `CrmCustomerAdapter`, `ReportBuilder`, event `OrderPlaced`) and add a one-line comment saying *why* the pattern is there. Never use a pattern name for code that doesn't implement it.
8. **Explain the decision.** When you introduce or remove a pattern, state: problem → pattern → simpler alternative considered and why it was not enough (§11).
9. **Removing a pattern is fine.** If the anticipated variation never came or the pattern makes code harder to follow, simplify it back.
10. **No mutable global state.** No Singletons or service locators as a substitute for dependency injection; pass dependencies in via constructor or parameters.

## 2. Decision procedure

Run this before adding any abstraction:

1. **Name the problem.** What varies (algorithm, state, data source, object creation, interface, structure)? Which coupling hurts (duplication, shotgun changes, untestable code)?
2. **Sketch the simplest solution without a pattern.** If it meets the requirement cleanly → implement it and stop.
3. **Look for evidence (§4).** Concrete signals only: ≥ 2 variants exist now; the same branching appears in ≥ 2 places; a class changes for more than one reason; vendor types leak into domain code; a test cannot be written without real I/O.
4. **Choose the pattern** (§4, §6, §7) and rule out look-alikes (§8).
5. **Choose the lightest form** (§9).
6. **Cost check.** Count new types, files and indirections. Will a newcomer understand the code faster? Will future changes be more local? If not → back to step 2.
7. **Implement in small steps.** Behavior unchanged, tests green, names and comment per rule 7, explanation per rule 8.

**Heuristics**
- 1st variant: write it concretely. 2nd variant: a conditional or a map of functions is fine. 3rd variant, or the same conditional in a 2nd place: introduce the pattern (rule of three).
- One `switch` on a type is acceptable in exactly one place (e.g. inside a factory). The same branching in several places is the strongest signal for polymorphism (Strategy, State).
- A pattern must reduce the sum of duplication, branching and change locations. If it only adds files, it is over-engineering.
- Prefer composition-based patterns (Strategy, Decorator, State, Bridge) over inheritance-based ones (Template Method, Factory Method).

**Right-sizing examples** (pseudocode)

```text
1  Variants → Strategy as a map of functions
   Need:        CSV, XLSX and JSON export; more formats announced
   Too much:    ExporterFactoryProvider → AbstractExporterFactory → CsvExporterFactory → CsvExporter extends BaseExporter
   Right:       exporters = { csv: toCsv, xlsx: toXlsx, json: toJson }            // Strategy
                export(rows, format) = exporters[format](rows)

2  Status-dependent behavior → start with a transition table
   Need:        order status DRAFT → SUBMITTED → APPROVED | REJECTED
   Right:       allowed = { DRAFT: [SUBMITTED], SUBMITTED: [APPROVED, REJECTED] }
                transition(order, to): reject unless to in allowed[order.status]
   Upgrade:     State objects only once several operations behave differently per status

3  External system → one adapter at the boundary
   Need:        read customers from a CRM API
   Too little:  vendor DTOs and HTTP calls spread through domain code
   Too much:    factory + abstract base client + client hierarchy for a single vendor
   Right:       interface CustomerSource { listCustomers(since) }                  // domain terms
                CrmCustomerAdapter implements CustomerSource                       // maps DTOs, paging, errors

4  Notifications → direct call until there are several receivers
   One:         invoiceService.send() calls mailer.sendInvoice(invoice)
   Several:     publish(InvoiceSent { invoiceId }); mail, audit log and CRM sync subscribe   // Observer
```

## 3. Design principles (the book's nine)

| # | Principle | Instruction |
|---|---|---|
| 1 | **Encapsulate what varies** | Identify what changes with new requirements and move exactly that behind a stable interface; leave the stable part untouched. The root of nearly every pattern. |
| 2 | **Program to an interface, not an implementation** | Use the supertype (interface, abstract class, protocol, function type) for fields, parameters and return types; concrete classes appear only where objects are created and wired. |
| 3 | **Favor composition over inheritance** | *Has-a* beats *is-a*: behavior becomes swappable at runtime and subclass explosions disappear. |
| 4 | **Loose coupling between interacting objects** | Objects know as little as possible about each other — ideally only an interface. |
| 5 | **Open–Closed** | Open for extension, closed for modification: add behavior by adding code, not by editing tested code — but only where change is *likely*. The book warns that applying it everywhere adds needless abstraction and complexity. |
| 6 | **Dependency Inversion** | Depend on abstractions, not concrete classes — high- and low-level modules alike. Guidelines to strive for, not laws: no variable holds a concrete class (use factories/injection); no class derives from a concrete class; no subclass overrides an implemented base method. Instantiating stable classes (strings, standard library, value objects) directly is fine. |
| 7 | **Least Knowledge (Law of Demeter)** | Inside a method, call only methods of the object itself, its fields, its parameters and objects it creates. Replace `order.getCustomer().getAddress().getCity()` with `order.shippingCity()`. Fluent APIs and plain data structures (DTOs) are exempt. |
| 8 | **Hollywood Principle** — "don't call us, we'll call you" | High-level components decide *when* low-level components run; low-level components plug in but never call up (no dependency cycles). Basis of Template Method, callbacks and frameworks. |
| 9 | **Single Responsibility** | A class has one reason to change. If it changes for two unrelated reasons, split it. |

## 4. Signal → pattern lookup

| Signal in code or requirement | Pattern | Lightest sensible form |
|---|---|---|
| Several interchangeable variants of an algorithm or rule (pricing, discounts, export format, validation, scoring); `if/switch` on a mode | Strategy | function parameter or map `key → function` |
| Behavior depends on a status field; the same `switch(status)` in several methods; transition rules scattered | State | enum + allowed-transitions table; state objects once several methods depend on the state |
| Other parts must react to changes or events without the source knowing them | Observer | framework events / signals / callback list |
| Combinable cross-cutting behavior (logging, caching, retry, metrics, auth) around an object; subclass explosion from combinations | Decorator | wrapper / higher-order function / middleware |
| `new ConcreteX` chosen by type or config in several places; duplicated creation logic | Simple Factory | one function `createX(config)` |
| A framework or base class must let subclasses choose the concrete product | Factory Method | overridable `create…()` hook; often a factory parameter suffices |
| Families of related objects that must match (per tenant, platform, database dialect, cloud provider) | Abstract Factory | record/object of factory functions per family |
| Exactly one shared resource (configuration, connection pool, cache) | Singleton → prefer one instance from the composition root, injected | module-level instance / DI "singleton" lifetime |
| Actions must be queued, logged, scheduled, retried, undone or bound to UI controls | Command | closure; object with `execute/undo` only for undo, persistence or audit |
| External library, API or legacy code with an unfitting interface; vendor types leak into domain code | Adapter | one adapter class/function at the boundary |
| Callers repeat the same multi-step sequence against a complex subsystem | Facade | one service with a few use-case methods |
| Several processes share the same sequence of steps; only some steps differ | Template Method | function taking step callbacks; inheritance only if the framework requires it |
| Traverse a custom collection or a paged/streamed source without exposing internals | Iterator | language iterator / (async) generator |
| Tree structures (menus, folders, org units, cost-center or account hierarchies, bills of materials, filter expressions, UI trees) handled uniformly | Composite | one interface with a recursive method |
| Control access behind the same interface: lazy loading, caching, permissions, rate limiting, remote calls | Proxy | wrapper with the same interface / built-in proxy mechanism |
| Two independent dimensions vary (e.g. report type × output format) → classes like `PdfSalesReport`, `CsvSalesReport`, … | Bridge | composition: the abstraction holds the implementation as a field |
| Object with many optional parts or a multi-step, validated construction | Builder | named/default parameters, options object, record/dataclass; a real Builder only for stepwise construction or invariants |
| A request passes through a sequence of handlers (validation, middleware, approval levels, routing) | Chain of Responsibility | list of handler functions / middleware pipeline |
| Very many similar objects with large shared state and a *measured* memory problem | Flyweight | cache/intern the shared immutable parts |
| A small, stable rule or query language must be evaluated | Interpreter | AST + Composite; a parser library once the grammar grows |
| Many objects coordinate with each other (n:m) and the coordination logic is scattered | Mediator | one coordinator / workflow service |
| State must be saved and restored (undo, drafts, checkpoints) without breaking encapsulation | Memento | immutable snapshot (copy / value object) |
| Creation is expensive or complex and copying a configured template suffices | Prototype | clone/copy/`with` expression |
| Many changing operations over a stable set of heterogeneous types (AST, document model) | Visitor | pattern matching over a closed (sealed/union) type set |
| UI with data, presentation and input handling | MVC (compound) | the UI framework's built-in model |

## 5. Cost tiers

**Usually worth it once the signal is present** (cheap, high payoff):
- Adapter at boundaries to external services, SDKs and data sources.
- Simple Factory as the single place for type-dependent creation.
- Strategy as functions or a map instead of growing conditionals.
- Iterators/generators for streaming large or paged data.
- Facade (application service) per use case over several repositories or clients.
- Composite for real hierarchies.
- Constructor injection instead of Singleton.
- The platform's event mechanism (Observer) for decoupled notifications.

**Only with strong, concrete evidence** (expensive, easy to overuse): Abstract Factory, Visitor, Interpreter, Flyweight, Mediator, Bridge, State as a class hierarchy, Template Method via inheritance, a hand-rolled event bus, Singleton, deep Decorator stacks, dynamically assembled handler chains.

## 6. Pattern catalog — the book's core patterns

Entries cover intent, when to use and when to avoid, a minimal implementation, the lightest form, the book's example and pitfalls. The book's class diagrams are Java-centric; implement the intent idiomatically in the project's language (§9).

### Strategy
- **Intent:** encapsulate a family of interchangeable algorithms behind one interface; the client picks or receives one without knowing its details.
- **Use when:** ≥ 2 variants of a behavior exist now and are selected by configuration, input or user; variants should be testable in isolation.
- **Avoid when:** only one variant exists; variants differ only by a value (use a parameter).
- **How:** (1) smallest possible interface — usually one function, e.g. `calculate(order) → Money`; (2) one implementation per variant; (3) inject it into the context via constructor or parameter — the context never instantiates it; (4) select the variant in exactly one place (factory, configuration, map).
- **Lightest form:** a map of functions (§2, example 1).
- **Book:** duck simulator — flying and quacking become swappable behavior objects instead of methods overridden across a duck class hierarchy.
- **Pitfalls:** Strategy vs. State vs. Template Method → §8.

### Observer
- **Intent:** one-to-many dependency — when a subject changes, all registered observers are notified; the subject knows only the observer interface.
- **Use when:** several receivers react to an event and the source must not know them: domain events, UI updates, notifications, cache invalidation, job/pipeline status.
- **Avoid when:** exactly one fixed receiver → direct call. Ordering, transactions or error handling across receivers matter → explicit orchestration (or Mediator).
- **How:** `subscribe(handler) → unsubscribe`, `publish(event)`. Typed, past-tense events (`OrderPlaced`) with a minimal payload (IDs); observers pull further data when needed (the book considers pull the cleaner variant). Never rely on notification order. Always support unsubscribing (memory leaks). Define what happens when one observer fails.
- **Lightest form:** the platform's event mechanism (events/delegates, event emitters, signals, reactive streams). Don't build an event bus if one exists.
- **Book:** weather station — displays subscribe to measurement updates.
- **Pitfalls:** implicit control flow and event cascades; document who listens to what.

### Decorator
- **Intent:** add responsibilities to an object at runtime by wrapping it in objects with the same interface — a flexible alternative to subclassing.
- **Use when:** cross-cutting behavior (logging, caching, retry, timing, validation, compression) must be combinable; subclass combinations explode (`CachedLoggingRepository`).
- **Avoid when:** client code checks the concrete type (decorators hide it); only one fixed combination is ever needed; wrapper order is critical and non-obvious.
- **How:** the decorator implements the component interface, holds the wrapped component, delegates and adds behavior before/after. Assemble the stack in one place (composition root or factory) and document the order.
- **Lightest form:** higher-order function or middleware; language-level function decorators.
- **Book:** coffee shop — condiments wrap a beverage and add to its price; Java I/O streams.
- **Pitfalls (book):** many small classes; more complex instantiation (pair with a factory or builder); type-specific client code breaks.

### Factories (Simple Factory, Factory Method, Abstract Factory)
- **Intent:** encapsulate object creation so client code does not depend on concrete classes.
- **Simple Factory** (an idiom rather than a formal pattern): one function or class decides which concrete class to create. The default whenever the same `new A` / `new B` decision would otherwise appear in several places.
- **Factory Method:** a base class runs a workflow and calls an abstract `create…()`; subclasses decide the product. Use only where such a hierarchy already exists (typically frameworks). A specialization of Template Method.
- **Abstract Factory:** an interface for creating *families* of related objects (e.g. per database dialect: connection + query builder + migrator). Use only with ≥ 2 families whose members must stay consistent.
- **Avoid when:** objects have no variation; a factory just wraps `new X()`; a DI container already does the job.
- **How:** the factory is the right home for the one remaining type `switch`; return the abstraction, not the concrete type.
- **Book:** pizza store — regional stores implement `createPizza()` (Factory Method), regional ingredient factories supply matching ingredients (Abstract Factory); motivates Dependency Inversion.

### Singleton
- **Intent:** guarantee exactly one instance plus a global access point.
- **Use when:** rarely — a truly process-wide unique resource where no DI is available.
- **Prefer:** create one instance at the composition root and inject it (DI "singleton" lifetime); in module-based languages a module-level instance.
- **Avoid when:** used as a global variable for configuration or services — hides dependencies, hinders tests and mixes two responsibilities (managing the instance and doing the actual job), as the book itself concedes.
- **If unavoidable:** thread-safe initialization (eager initialization or the language's lazy primitive), preferably immutable, resettable in tests.
- **Book:** chocolate boiler controller; multithreading pitfalls (synchronization, eager creation, double-checked locking).

### Command
- **Intent:** encapsulate a request as an object, decoupling the invoker from the receiver; enables parameterization, queuing, logging and undo.
- **Use when:** undo/redo; job queues, retries, scheduled or deferred execution; audit log or replay; the same action triggered from several UI controls; macros and batches.
- **Avoid when:** a plain method call suffices.
- **How:** `execute()` (+ `undo()` if needed); the command holds receiver and parameters; the invoker knows only the interface; macro command = list of commands; a no-op command (Null Object) instead of null checks; for queues and persistence make commands serializable (name + parameters as data).
- **Lightest form:** a closure (`() => light.on()`); upgrade to an object only for undo, serialization or logging.
- **Book:** home-automation remote control with programmable slots, undo and a "party mode" macro.

### Adapter
- **Intent:** convert the interface of an existing class into the interface the client expects.
- **Use when:** wrapping external APIs/SDKs, legacy code or heterogeneous data sources (ERP, CRM, file formats) behind your own domain interface; keeping vendor types out of the domain; making boundaries swappable and testable.
- **Avoid when:** the interface already fits — no pass-through layers.
- **How:** define the target interface from the client's perspective in domain terms; the adapter implements it and delegates to the adaptee via composition (object adapter, not class adapter via inheritance); map types, units, errors and paging inside the adapter; no business logic in adapters.
- **Book:** a turkey adapted to act as a duck; an old `Enumeration` adapted to `Iterator`.

### Facade
- **Intent:** provide a simplified, unified interface to a complex subsystem.
- **Use when:** callers repeat the same sequence across several subsystem classes; a use-case/application-service layer over repositories and clients; a library with many knobs of which you need two or three flows.
- **Avoid when:** it turns into a god object; it only forwards calls 1:1.
- **How:** few, use-case-oriented methods; the subsystem stays directly accessible for special cases; several facades per subsystem are fine; orchestration only, no core domain logic.
- **Book:** home theater — one `watchMovie()` replaces a dozen device calls; introduces the Principle of Least Knowledge.

### Template Method
- **Intent:** define the skeleton of an algorithm in one method and let subclasses implement individual steps; hooks provide optional steps.
- **Use when:** several processes share the exact step sequence and only some steps differ (e.g. import: read → validate → transform → write); framework extension points.
- **Prefer:** composition — a workflow function that receives the varying steps as functions or strategies. Use inheritance only when a framework mandates it or the hierarchy already exists.
- **How:** make the template method non-overridable (`final`/`sealed`); abstract mandatory steps; hooks with sensible defaults; follows the Hollywood Principle.
- **Book:** coffee and tea share one preparation recipe with varying steps; a hook decides on condiments; sorting with a compare method is a real-world variant.

### Iterator
- **Intent:** traverse the elements of a collection sequentially without exposing its internal representation.
- **Use when:** custom collections; different internal structures must be traversed uniformly; lazy or streamed access (API paging, large files, database cursors).
- **How:** always use the language mechanism (generators/`yield`, iterable protocols, async iteration for paged I/O); never hand out the internal mutable collection — return an iterator or a read-only view.
- **Avoid:** hand-written iterator classes where the language provides iteration.
- **Book:** merging two restaurants whose menus use different collection types; introduces Single Responsibility.

### Composite
- **Intent:** compose objects into trees representing part–whole hierarchies; clients treat leaves and composites uniformly.
- **Use when:** real trees — menus, folders, org units, cost-center or account hierarchies, bills of materials, report or dashboard layouts, boolean filter expressions, UI component trees — with recursive operations (sum, render, validate).
- **Avoid when:** the structure is flat or only one level deep.
- **How:** one common interface (`total()`, `render()`); composites hold children and delegate recursively. Choose transparency vs. safety consistently: child management on the common interface (transparent) or only on the composite (safe). Guard against cycles.
- **Book:** menus containing sub-menus; the book notes that Composite trades some Single Responsibility for transparency.

### State
- **Intent:** let an object change its behavior when its internal state changes, by delegating to one state object per state — it appears to change its class.
- **Use when:** several methods branch on the same status; transitions follow rules (order, approval workflow, ticket, contract, job run); new states are expected.
- **Avoid when:** few states and little state-dependent behavior → enum + allowed-transitions table (§2, example 2). For complex workflows consider an established state-machine library.
- **How:** a state interface with the state-dependent actions; the context holds the current state and delegates; transitions are controlled either by the context or by the states — decide once; reject invalid actions explicitly (error, never silent ignore); stateless state objects can be shared.
- **Book:** gumball machine — nested `if` cascades become state classes, which makes adding a new "winner" state easy.

### Proxy
- **Intent:** a surrogate with the same interface that controls access to another object.
- **Variants:** remote, virtual (lazy creation), protection (permissions), caching, synchronization, smart reference (counting, logging), firewall, copy-on-write.
- **Use when:** lazy loading, caching, access control, rate limiting or remote stubs should be transparent to the client.
- **Avoid when:** the client must be aware of the difference (latency, network failures) → make it explicit instead. Prefer framework mechanisms (ORM lazy loading, HTTP-client caching, runtime/dynamic proxies).
- **How:** implement the subject's interface, hold or lazily create the real subject, wrap delegation with the access logic.
- **Book:** remote monitoring of gumball machines (remote proxy), lazily loaded album covers (virtual proxy), a matchmaking service secured with a dynamic proxy (protection proxy).

### Compound patterns & MVC
- **Intent:** combine patterns into a solution for a general problem. MVC = Observer (model notifies views) + Strategy (the controller is the view's strategy) + Composite (nested view components); Adapter plugs in a different model.
- **Instruction:** in UI frameworks use the framework's own model instead of hand-rolling MVC. Keep domain logic and state free of UI dependencies, keep presentation free of domain logic, keep input handling separate.
- **Book:** a duck simulator combining Adapter, Decorator, Abstract Factory, Composite and Observer; a DJ beat-controller app built as MVC.

## 7. Further patterns (book appendix "Leftover Patterns")

| Pattern | Intent | Use when | Caution / lighter form |
|---|---|---|---|
| Bridge | Vary abstraction and implementation independently in two hierarchies | Two independent dimensions (report × format, remote control × TV) | Not for a single dimension; field composition instead of cross-product classes |
| Builder | Encapsulate the stepwise construction of a complex product | Many optional parts, invariants, multi-step assembly, immutable results, test-data builders | Named/default parameters, options objects, records/dataclasses often suffice |
| Chain of Responsibility | Give several handlers a chance to handle a request | Middleware, validation chains, approval levels, routing | Guarantee a default handler; make the order explicit; harder to debug |
| Flyweight | Share intrinsic state among many fine-grained objects | Measured memory pressure from very many similar objects | Only after profiling; pass extrinsic state in |
| Interpreter | Represent a grammar as classes and evaluate sentences | Small, stable DSL (filter expressions, rules) | Switch to a parser library once the grammar grows |
| Mediator | Centralize complex communication between related objects | n:m coordination, scattered coordination logic (dialogs, workflows) | The mediator must not become a god object |
| Memento | Capture and restore an object's state without breaking encapsulation | Undo, drafts, checkpoints, save games | Immutable snapshots; watch memory usage |
| Prototype | Create objects by copying a configured template | Creation is expensive or complex, or the type is only known at runtime | Choose deep vs. shallow copy deliberately |
| Visitor | Add operations to an object structure without changing its classes | Stable type set with many, changing operations (AST, document model) | Breaks encapsulation; new types are costly; prefer pattern matching over sealed/union types |

## 8. Look-alikes — choose by intent

| Group | Pattern | Distinguishing intent |
|---|---|---|
| Wrappers | Adapter | *changes* the interface into the one the client expects |
| | Decorator | *same* interface, *adds* behavior; stackable |
| | Proxy | *same* interface, *controls access* (lazy, remote, permissions, cache) |
| | Facade | *new, simplified* interface over *many* objects |
| Varying algorithms | Strategy | composition; the client chooses the algorithm; rarely changes during the object's life |
| | State | composition; the object switches its own behavior as its state changes |
| | Template Method | inheritance; fixed skeleton, subclasses fill in steps |
| Creation | Simple Factory | one place decides the concrete class |
| | Factory Method | a subclass decides (inheritance) |
| | Abstract Factory | consistent families of objects (composition) |
| | Builder | stepwise construction with many options |
| | Prototype | copy a configured template |
| | Singleton | exactly one instance (prefer DI) |
| Communication | Observer | 1:n broadcast; the subject doesn't know its receivers |
| | Mediator | n:m coordination through one hub |
| | Chain of Responsibility | one request travels along handlers until one handles it |
| | Command | a request as an object (queue, log, undo) |

## 9. Language idioms — lightest form per language

| Pattern | TypeScript / JavaScript | Python | C# / .NET | Java |
|---|---|---|---|---|
| Strategy | function type, `Record<Key, Fn>` | callable, dict of functions, `Protocol` | `Func<…>` or interface + DI | functional interface + lambda |
| Observer | `EventTarget`/`EventEmitter`, signals, RxJS | callback list, framework signals | `event`/delegates, `IObservable<T>` | listener interface, `Flow`/reactive library (not the deprecated `java.util.Observable`) |
| Decorator | higher-order function, middleware | `@decorator` for functions, wrapper class for objects | wrapper class registered via DI | wrapper class |
| Iterator | `function*`, `Symbol.iterator`, `for await` | generators (`yield`), `__iter__`, async generators | `IEnumerable<T>` + `yield return`, `IAsyncEnumerable<T>` | `Iterable`/`Iterator`, streams |
| Singleton | exported module instance | module-level instance | DI `AddSingleton`, `Lazy<T>` | DI singleton scope, `enum` |
| Builder | options object with defaults | keyword arguments, `@dataclass` defaults | object initializer, `record` + `with` | builder class, records |
| Command | closure | callable, `functools.partial` | `Action`/`Func`, command class | `Runnable`/lambda, command class |
| Proxy | `Proxy` object | `__getattr__` delegation | `DispatchProxy`, DI decoration | `java.lang.reflect.Proxy` |
| Prototype | `structuredClone`, spread | `copy.copy`/`copy.deepcopy`, `dataclasses.replace` | `record` + `with` | copy constructor |
| Template Method | function taking step callbacks | function taking callables, `ABC` if a hierarchy exists | delegate parameters or abstract class | lambdas or abstract class |
| State | union/enum + transition map; classes when needed | `Enum` + transition dict; classes when needed | `enum` + transition table; classes when needed | `enum` with constant-specific methods; classes when needed |
| Visitor | discriminated union + exhaustive `switch` | `match` statement | `switch` expression over records | sealed interface + pattern-matching `switch` |

## 10. Warning signs

**Over-engineering — do not:**
- Use a favorite pattern everywhere ("golden hammer" anti-pattern).
- Add speculative generality: interfaces, factories, strategies or plugin systems with exactly one implementation "for later".
- Stack patterns: a factory that creates a builder that configures a strategy — for a single variant.
- Build more than one level of subclasses below an abstraction (unless a framework requires it), or inherit just to reuse code.
- Use Singletons or service locators instead of dependency injection.
- Use events/observers for flows that are really sequential (hidden control flow, ordering bugs, hard debugging).
- Create pass-through layers: adapters, facades or "services" that only forward 1:1.
- Grow god facades or god mediators that know everything.
- Use pattern names as labels without the pattern (`UserManagerFactoryHelper`).
- Organize folders by pattern type (`/factories`, `/strategies`) instead of by feature or domain.
- Build a generic framework for a single use case.

**Under-engineering — a pattern is probably missing when you see:**
- The same `switch`/`if` chain on a type or status in several places → Strategy/State.
- Shotgun surgery: one business change requires edits in many files → encapsulate what varies.
- Methods with mode flags (`process(data, isB2B, useNewPricing, legacyMode)`) → Strategy or separate functions.
- Vendor/SDK types inside domain logic → Adapter.
- Copy-pasted classes that differ in a few lines → Strategy or Template Method.
- Code that cannot be tested because it creates I/O objects internally → injection + interface at the boundary.
- Subclass explosion from combining features → Decorator or Bridge.

## 11. Working agreements

- **Refactoring is pattern time.** Let patterns emerge while refactoring real code instead of designing them up front.
- **Refactor safely:** tests (or characterization tests) first → smallest step (extract function, extract interface) → move variants → select the variant in one place → delete the old conditionals → tests green. Never change behavior and structure in the same step.
- **Reuse before adding:** search the codebase for an existing mechanism (DI registrations, event bus, middleware, base classes) before creating a new one.
- **Place code by feature,** next to its users; make pattern roles visible through names, not folders.
- **Keep it testable:** strategies, adapters and state objects must be testable in isolation; inject fakes through interfaces at the boundaries.
- **When unsure,** implement the simpler design and mention the pattern as a possible next step instead of building it.
- **In code reviews,** check changes against §10 and propose the lightest fix — removing an unneeded pattern is as valid as adding a missing one.
- **Report** every introduced or removed pattern in your response, e.g.:

```text
Pattern:  Strategy for shipping-cost rules
Signal:   the same carrier switch in checkout, invoice and quote services; a 4th carrier is being added
Rejected: keeping the switch — three places would change for every new carrier
```

## 12. Book summary — *Head First Design Patterns*

Eric Freeman & Elisabeth Robson (with Kathy Sierra & Bert Bates), 2nd edition, O'Reilly 2020; German edition *Entwurfsmuster von Kopf bis Fuß*. A visual, example-driven introduction to the classic "Gang of Four" patterns and the OO principles behind them; code examples in Java.

| Ch. | Topic | Pattern(s) | Book example | Key lesson |
|---|---|---|---|---|
| 1 | Intro to design patterns | Strategy | duck simulator | Encapsulate what varies; program to interfaces; composition over inheritance |
| 2 | Keeping objects informed | Observer | weather station | Loose coupling |
| 3 | Decorating objects | Decorator | coffee shop beverages | Open–Closed Principle |
| 4 | Object creation | Simple Factory, Factory Method, Abstract Factory | pizza store | Dependency Inversion |
| 5 | One-of-a-kind objects | Singleton | chocolate boiler | Thread safety, cost of global state |
| 6 | Encapsulating invocation | Command | remote control | Undo, macros, queues, logging |
| 7 | Being adaptive | Adapter, Facade | turkey as duck, home theater | Principle of Least Knowledge |
| 8 | Encapsulating algorithms | Template Method | coffee and tea | Hollywood Principle |
| 9 | Well-managed collections | Iterator, Composite | merging restaurant menus | Single Responsibility |
| 10 | The state of things | State | gumball machine | States as objects instead of conditionals |
| 11 | Controlling object access | Proxy | gumball monitor, album covers, matchmaking | Remote, virtual and protection proxies |
| 12 | Patterns of patterns | Compound patterns, MVC | duck simulator, DJ app | Patterns combine into larger solutions |
| 13 | Patterns in the real world | — | — | Definition, categories, anti-patterns, using patterns wisely |
| App. | Leftover patterns | Bridge, Builder, Chain of Responsibility, Flyweight, Interpreter, Mediator, Memento, Prototype, Visitor | — | Know they exist; use them sparingly |

**Key messages**
- A pattern is a solution to a problem in a context: a recurring situation, a goal with constraints, and a general design that resolves them. Patterns are discovered rather than invented, and they provide design ideas, not code.
- Most patterns are about change: letting one part of a system vary independently of the others.
- Principles come first; whoever has internalized them recognizes where a pattern fits.
- Pattern names are a shared vocabulary that makes design discussions shorter and more precise — use them in code, comments and reviews.
- Categories: **creational** (Singleton, Factory Method, Abstract Factory, Builder, Prototype), **structural** (Adapter, Bridge, Composite, Decorator, Facade, Flyweight, Proxy), **behavioral** (Chain of Responsibility, Command, Interpreter, Iterator, Mediator, Memento, Observer, State, Strategy, Template Method, Visitor).
- Simplicity wins: overusing patterns produces over-engineered code. Start simple, add a pattern when the need actually emerges (often during refactoring), and remove patterns that no longer earn their keep. Beginners see patterns everywhere; experienced designers use them where they fit naturally.
