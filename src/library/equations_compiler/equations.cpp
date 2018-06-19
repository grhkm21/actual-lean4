/*
Copyright (c) 2014 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.

Author: Leonardo de Moura
*/
#include <algorithm>
#include <string>
#include "runtime/sstream.h"
#include "util/list_fn.h"
#include "util/fresh_name.h"
#include "kernel/expr.h"
#include "kernel/abstract.h"
#include "kernel/instantiate.h"
#include "kernel/for_each_fn.h"
#include "kernel/find_fn.h"
#include "kernel/replace_fn.h"
#include "library/error_msgs.h"
#include "library/exception.h"
#include "library/kernel_serializer.h"
#include "library/io_state_stream.h"
#include "library/annotation.h"
#include "library/util.h"
#include "library/locals.h"
#include "library/constants.h"
#include "library/normalize.h"
#include "library/pp_options.h"
#include "library/equations_compiler/equations.h"

namespace lean {
static name * g_equations_name                 = nullptr;
static name * g_equation_name                  = nullptr;
static name * g_no_equation_name               = nullptr;
static name * g_inaccessible_name              = nullptr;
static name * g_equations_result_name          = nullptr;
static name * g_as_pattern_name                = nullptr;
static std::string * g_equations_opcode        = nullptr;

[[ noreturn ]] static void throw_asp_ex() { throw exception("unexpected occurrence of 'equations' expression"); }

bool operator==(equations_header const & h1, equations_header const & h2) {
    return
        h1.m_num_fns == h2.m_num_fns &&
        h1.m_fn_names == h2.m_fn_names &&
        h1.m_fn_actual_names == h2.m_fn_actual_names &&
        h1.m_is_private == h2.m_is_private &&
        h1.m_is_lemma == h2.m_is_lemma &&
        h1.m_is_meta == h2.m_is_meta &&
        h1.m_is_noncomputable == h2.m_is_noncomputable &&
        h1.m_aux_lemmas == h2.m_aux_lemmas &&
        h1.m_prev_errors == h2.m_prev_errors &&
        h1.m_gen_code == h2.m_gen_code;
}

[[ noreturn ]] static void throw_eqs_ex() { throw exception("unexpected occurrence of 'equations' expression"); }

class equations_macro_cell : public macro_definition_cell {
    equations_header m_header;
public:
    equations_macro_cell(equations_header const & h):m_header(h) {}
    virtual name get_name() const override { return *g_equations_name; }
    virtual expr check_type(expr const &, abstract_type_context &, bool) const override { throw_eqs_ex(); }
    virtual optional<expr> expand(expr const &, abstract_type_context &) const override { throw_eqs_ex(); }
    virtual void write(serializer & s) const override {
        s << *g_equations_opcode << m_header.m_num_fns << m_header.m_is_private << m_header.m_is_meta
          << m_header.m_is_noncomputable << m_header.m_is_lemma << m_header.m_aux_lemmas << m_header.m_prev_errors << m_header.m_gen_code;
        s << m_header.m_fn_names;
        s << m_header.m_fn_actual_names;
    }
    virtual bool operator==(macro_definition_cell const & other) const override {
        if (auto other_ptr = dynamic_cast<equations_macro_cell const *>(&other)) {
            return m_header == other_ptr->m_header;
        } else {
            return false;
        }
    }
    equations_header const & get_header() const { return m_header; }
};

static kvmap * g_as_pattern = nullptr;
static kvmap * g_equation                  = nullptr;
static kvmap * g_equation_ignore_if_unused = nullptr;
static kvmap * g_no_equation               = nullptr;

expr mk_equation(expr const & lhs, expr const & rhs, bool ignore_if_unused) {
    if (ignore_if_unused)
        return mk_mdata(*g_equation_ignore_if_unused, mk_app(lhs, rhs));
    else
        return mk_mdata(*g_equation, mk_app(lhs, rhs));
}
expr mk_no_equation() { return mk_mdata(*g_no_equation, mk_Prop()); }

bool is_equation(expr const & e) {
    return is_mdata(e) && get_bool(mdata_data(e), *g_equation_name);
}

bool ignore_equation_if_unused(expr const & e) {
    lean_assert(is_equation(e));
    return *get_bool(mdata_data(e), *g_equation_name);
}

bool is_lambda_equation(expr const & e) {
    if (is_lambda(e))
        return is_lambda_equation(binding_body(e));
    else
        return is_equation(e);
}

expr const & equation_lhs(expr const & e) { lean_assert(is_equation(e)); return app_fn(mdata_expr(e)); }
expr const & equation_rhs(expr const & e) { lean_assert(is_equation(e)); return app_arg(mdata_expr(e)); }
bool is_no_equation(expr const & e) { return is_mdata(e) && get_bool(mdata_data(e), *g_no_equation_name); }

bool is_lambda_no_equation(expr const & e) {
    if (is_lambda(e))
        return is_lambda_no_equation(binding_body(e));
    else
        return is_no_equation(e);
}

expr mk_inaccessible(expr const & e) { return mk_annotation(*g_inaccessible_name, e); }
bool is_inaccessible(expr const & e) { return is_annotation(e, *g_inaccessible_name); }

expr mk_as_pattern(expr const & lhs, expr const & rhs) {
    return mk_mdata(*g_as_pattern, mk_app(lhs, rhs));
}
bool is_as_pattern(expr const & e) {
    return is_mdata(e) && get_bool(mdata_data(e), *g_as_pattern_name);
}
expr get_as_pattern_lhs(expr const & e) {
    lean_assert(is_as_pattern(e));
    return app_fn(mdata_expr(e));
}
expr get_as_pattern_rhs(expr const & e) {
    lean_assert(is_as_pattern(e));
    return app_arg(mdata_expr(e));
}

bool is_equations(expr const & e) { return is_macro(e) && macro_def(e).get_name() == *g_equations_name; }
bool is_wf_equations_core(expr const & e) {
    lean_assert(is_equations(e));
    return macro_num_args(e) >= 2 && !is_lambda_equation(macro_arg(e, macro_num_args(e) - 1));
}
bool is_wf_equations(expr const & e) { return is_equations(e) && is_wf_equations_core(e); }
unsigned equations_size(expr const & e) {
    lean_assert(is_equations(e));
    if (is_wf_equations_core(e))
        return macro_num_args(e) - 1;
    else
        return macro_num_args(e);
}
equations_header const & get_equations_header(expr const & e) {
    lean_assert(is_equations(e));
    return static_cast<equations_macro_cell const*>(macro_def(e).raw())->get_header();
}
unsigned equations_num_fns(expr const & e) {
    return get_equations_header(e).m_num_fns;
}
expr const & equations_wf_tactics(expr const & e) {
    lean_assert(is_wf_equations(e));
    return macro_arg(e, macro_num_args(e) - 1);
}

void to_equations(expr const & e, buffer<expr> & eqns) {
    lean_assert(is_equations(e));
    unsigned sz = equations_size(e);
    for (unsigned i = 0; i < sz; i++)
        eqns.push_back(macro_arg(e, i));
}
expr mk_equations(equations_header const & h, unsigned num_eqs, expr const * eqs) {
    lean_assert(h.m_num_fns > 0);
    lean_assert(num_eqs > 0);
    lean_assert(std::all_of(eqs, eqs+num_eqs, [](expr const & e) {
                return is_lambda_equation(e) || is_lambda_no_equation(e);
            }));
    macro_definition def(new equations_macro_cell(h));
    return mk_macro(def, num_eqs, eqs);
}
expr mk_equations(equations_header const & h, unsigned num_eqs, expr const * eqs, expr const & tacs) {
    lean_assert(h.m_num_fns > 0);
    lean_assert(num_eqs > 0);
    lean_assert(std::all_of(eqs, eqs+num_eqs, is_lambda_equation));
    buffer<expr> args;
    args.append(num_eqs, eqs);
    args.push_back(tacs);
    macro_definition def(new equations_macro_cell(h));
    return mk_macro(def, args.size(), args.data());
}
expr update_equations(expr const & eqns, buffer<expr> const & new_eqs) {
    lean_assert(is_equations(eqns));
    lean_assert(!new_eqs.empty());
    if (is_wf_equations(eqns)) {
        return copy_pos(eqns, mk_equations(get_equations_header(eqns), new_eqs.size(), new_eqs.data(),
                                           equations_wf_tactics(eqns)));
    } else {
        return copy_pos(eqns, mk_equations(get_equations_header(eqns), new_eqs.size(), new_eqs.data()));
    }
}

expr update_equations(expr const & eqns, equations_header const & header) {
    buffer<expr> eqs;
    to_equations(eqns, eqs);
    if (is_wf_equations(eqns)) {
        return copy_pos(eqns, mk_equations(header, eqs.size(), eqs.data(),
                                           equations_wf_tactics(eqns)));
    } else {
        return copy_pos(eqns, mk_equations(header, eqs.size(), eqs.data()));
    }
}

expr remove_wf_annotation_from_equations(expr const & eqns) {
    if (is_wf_equations(eqns)) {
        buffer<expr> eqs;
        to_equations(eqns, eqs);
        return copy_pos(eqns, mk_equations(get_equations_header(eqns), eqs.size(), eqs.data()));
    } else {
        return eqns;
    }
}

expr mk_equations_result(unsigned n, expr const * rs) {
    lean_assert(n > 0);
    expr r     = rs[n - 1];
    unsigned i = n - 1;
    while (i > 0) {
        --i;
        r = mk_app(rs[i], r);
    }
    kvmap m = set_nat(kvmap(), *g_equations_result_name, nat(n));
    r = mk_mdata(m, r);
    lean_assert(get_equations_result_size(r) == n);
    return r;
}

bool is_equations_result(expr const & e) { return is_mdata(e) && get_nat(mdata_data(e), *g_equations_result_name); }

unsigned get_equations_result_size(expr const & e) { return get_nat(mdata_data(e), *g_equations_result_name)->get_small_value(); }

static void get_equations_result(expr const & e, buffer<expr> & r) {
    lean_assert(is_equations_result(e));
    expr it    = mdata_expr(e);
    unsigned i = get_nat(mdata_data(e), *g_equations_result_name)->get_small_value();
    while (i > 1) {
        --i;
        lean_assert(is_app(it));
        r.push_back(app_fn(it));
        it = app_arg(it);
    }
    r.push_back(it);
}

expr get_equations_result(expr const & e, unsigned i) {
    buffer<expr> tmp;
    get_equations_result(e, tmp);
    return tmp[i];
}

void initialize_equations() {
    g_equations_name            = new name("equations");
    g_equation_name             = new name("equation");
    g_no_equation_name          = new name("no_equation");
    g_inaccessible_name         = new name("innaccessible");
    g_equations_result_name     = new name("equations_result");
    g_as_pattern_name           = new name("as_pattern");
    g_equation                  = new kvmap(set_bool(kvmap(), *g_equation_name, false));
    g_equation_ignore_if_unused = new kvmap(set_bool(kvmap(), *g_equation_name, true));
    g_no_equation               = new kvmap(set_bool(kvmap(), *g_no_equation_name, false));
    g_as_pattern                = new kvmap(set_bool(kvmap(), *g_as_pattern_name, true));
    g_equations_opcode          = new std::string("Eqns");
    register_annotation(*g_inaccessible_name);
    register_macro_deserializer(*g_equations_opcode,
                                [](deserializer & d, unsigned num, expr const * args) {
                                    equations_header h;
                                    d >> h.m_num_fns >> h.m_is_private >> h.m_is_meta >> h.m_is_noncomputable
                                      >> h.m_is_lemma >> h.m_aux_lemmas >> h.m_prev_errors >> h.m_gen_code;
                                    h.m_fn_names = read_names(d);
                                    h.m_fn_actual_names = read_names(d);
                                    if (num == 0 || h.m_num_fns == 0)
                                        throw corrupted_stream_exception();
                                    if (!is_lambda_equation(args[num-1]) && !is_lambda_no_equation(args[num-1])) {
                                        if (num <= 1)
                                            throw corrupted_stream_exception();
                                        return mk_equations(h, num-1, args, args[num-1]);
                                    } else {
                                        return mk_equations(h, num, args);
                                    }
                                });
}

void finalize_equations() {
    delete g_equations_opcode;
    delete g_as_pattern;
    delete g_equation;
    delete g_equation_ignore_if_unused;
    delete g_no_equation;
    delete g_as_pattern_name;
    delete g_equations_result_name;
    delete g_equations_name;
    delete g_equation_name;
    delete g_no_equation_name;
    delete g_inaccessible_name;
}
}
