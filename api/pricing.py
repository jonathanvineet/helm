"""Validated quotation inputs and decimal-based INR pricing."""
from decimal import Decimal, ROUND_HALF_UP

from pydantic import BaseModel, ConfigDict, Field


class Rates(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid")
    filament_per_gram: float = Field(2.5, ge=0, le=100000)
    machine_per_hour: float = Field(10, ge=0, le=100000)
    electricity_per_hour: float = Field(8, ge=0, le=100000)
    maintenance_percent: float = Field(5, ge=0, le=1000)
    risk_percent: float = Field(5, ge=0, le=1000)
    labour_percent: float = Field(10, ge=0, le=1000)
    design_percent: float = Field(5, ge=0, le=1000)
    packaging: float = Field(50, ge=0, le=1000000)
    profit_percent: float = Field(30, ge=0, le=1000)


class QuoteInput(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid")
    filament_grams: float = Field(gt=0, le=10000)
    print_time_minutes: float = Field(gt=0, le=525600)
    rates: Rates = Field(default_factory=Rates)


def calculate(grams, minutes, rates):
    d = lambda value: Decimal(str(value))
    hours = d(minutes) / 60
    filament = d(grams) * d(rates.filament_per_gram)
    machine = hours * d(rates.machine_per_hour)
    electricity = hours * d(rates.electricity_per_hour)
    subtotal = filament + machine + electricity
    buffer_percent = sum(d(value) for value in (
        rates.maintenance_percent, rates.risk_percent, rates.labour_percent, rates.design_percent
    ))
    buffers = subtotal * buffer_percent / 100
    manufacturing = subtotal + buffers + d(rates.packaging)
    profit = manufacturing * d(rates.profit_percent) / 100
    values = dict(filament=filament, machine=machine, electricity=electricity,
                  subtotal=subtotal, buffers=buffers, packaging=d(rates.packaging),
                  manufacturing=manufacturing, profit=profit, final_price=manufacturing + profit)
    return {key: float(value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))
            for key, value in values.items()}
